"""Both transports: one deployment identity, refused before anything runs.

The HTTP suite runs the real handler on a random loopback port with a real
``http.client`` connection; the stdio suite drives the real loop with ``StringIO``.
Neither opens a socket off loopback, and every test that refuses a call also
asserts that nothing was written.
"""

from __future__ import annotations

import http.client
import io
import json
import threading
import unittest
from pathlib import Path
from unittest import mock

from data_plane.errors import ContractError
from data_plane.model import Visibility

from apps.agent_facade import __main__ as cli
from apps.agent_facade import memory, server, sources
from apps.agent_facade.tests import support

TOKEN_HEADER = server.TOKEN_HEADER


class HttpTransportTestCase(support.FacadeCase):
    def setUp(self) -> None:
        super().setUp()
        self.server = server.build_server(self.facade, "127.0.0.1", 0)
        self.thread = threading.Thread(
            target=self.server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True
        )
        self.thread.start()
        self.addCleanup(self._stop)
        self.port = self.server.server_address[1]

    def _stop(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(5)

    def request(
        self,
        body: object,
        *,
        token: str | None = support.TOKEN,
        path: str = server.MCP_PATH,
        method: str = "POST",
    ) -> tuple[int, bytes]:
        payload = body if isinstance(body, bytes) else json.dumps(body).encode("utf-8")
        headers = {"Content-Type": "application/json"}
        if token is not None:
            headers[TOKEN_HEADER] = token
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        try:
            connection.request(method, path, body=payload, headers=headers)
            response = connection.getresponse()
            return response.status, response.read()
        finally:
            connection.close()

    def rpc(self, method: str, params: object = None, *, request_id: object = 1) -> dict:
        message: dict[str, object] = {"jsonrpc": "2.0", "method": method}
        if request_id is not None:
            message["id"] = request_id
        if params is not None:
            message["params"] = params
        status, raw = self.request(message)
        self.assertEqual(status, 200, raw)
        return json.loads(raw)

    def test_initialize_and_tools_list(self) -> None:
        result = self.rpc("initialize")["result"]
        self.assertEqual(result["protocolVersion"], server.PROTOCOL_VERSION)
        self.assertEqual(result["serverInfo"]["name"], "agent-facade-personal")

        tools = self.rpc("tools/list")["result"]["tools"]
        self.assertEqual(
            [tool["name"] for tool in tools], list(server.contracts.TOOL_NAMES)
        )

    def test_ping(self) -> None:
        self.assertEqual(self.rpc("ping")["result"], {})

    def test_tool_call_runs_with_the_right_token(self) -> None:
        result = self.rpc(
            "tools/call", {"name": "sources.describe", "arguments": {}}
        )["result"]
        self.assertFalse(result["isError"])
        self.assertEqual(result["structuredContent"]["deployment"], "personal")

    def test_memory_write_then_read_over_http(self) -> None:
        written = self.rpc(
            "tools/call",
            {
                "name": "memory.write",
                "arguments": {
                    "key": "preference-tea",
                    "value": "green tea",
                    "provenance": support.PROVENANCE,
                },
            },
        )["result"]
        self.assertFalse(written["isError"])
        read = self.rpc(
            "tools/call", {"name": "memory.read", "arguments": {"key": "preference-tea"}}
        )["result"]
        self.assertEqual(read["structuredContent"]["value"], "green tea")

    def test_missing_token_is_401(self) -> None:
        status, raw = self.request(
            {"jsonrpc": "2.0", "id": 1, "method": "tools/list"}, token=None
        )
        self.assertEqual(status, 401)
        error = json.loads(raw)["error"]
        self.assertEqual(error["code"], server.UNAUTHORIZED)
        self.assertNotIn(support.TOKEN, raw.decode("utf-8"))

    def test_wrong_token_is_401_and_has_no_side_effect(self) -> None:
        status, raw = self.request(
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/call",
                "params": {
                    "name": "memory.write",
                    "arguments": {
                        "key": "sneaky",
                        "value": "written without a token",
                        "provenance": support.PROVENANCE,
                    },
                },
            },
            token="not-the-deployment-token",
        )
        self.assertEqual(status, 401)
        self.assertEqual(json.loads(raw)["error"]["code"], server.UNAUTHORIZED)
        self.assertFalse((self.root / "local" / "sneaky.json").exists())
        self.assertEqual(self.refusal("memory.read", {"key": "sneaky"})["code"], "not_found")

    def test_empty_token_is_401(self) -> None:
        status, _ = self.request({"jsonrpc": "2.0", "id": 1, "method": "ping"}, token="")
        self.assertEqual(status, 401)

    def test_notification_is_202_and_empty(self) -> None:
        status, raw = self.request(
            {"jsonrpc": "2.0", "method": "notifications/initialized"}
        )
        self.assertEqual(status, 202)
        self.assertEqual(raw, b"")

    def test_notification_without_a_token_is_401(self) -> None:
        status, _ = self.request(
            {"jsonrpc": "2.0", "method": "notifications/initialized"}, token=None
        )
        self.assertEqual(status, 401)

    def test_unknown_method_is_32601(self) -> None:
        response = self.rpc("resources/list")
        self.assertEqual(response["error"]["code"], server.METHOD_NOT_FOUND)
        self.assertNotIn("result", response)

    def test_unknown_tool_is_an_error_result(self) -> None:
        response = self.rpc(
            "tools/call", {"name": "fs.read", "arguments": {"path": "/etc/passwd"}}
        )
        self.assertTrue(response["result"]["isError"])
        self.assertEqual(response["result"]["structuredContent"]["error"]["code"], "unknown_tool")

    def test_unknown_tools_call_field_is_refused(self) -> None:
        response = self.rpc(
            "tools/call", {"name": "ping", "arguments": {}, "extra": True}
        )
        self.assertEqual(response["error"]["code"], server.INVALID_PARAMS)

    def test_other_methods_and_paths_are_refused(self) -> None:
        status, raw = self.request(b"", method="GET")
        self.assertEqual(status, 405)
        self.assertIn(b"POST", raw)
        status, raw = self.request({"jsonrpc": "2.0", "id": 1, "method": "ping"}, path="/other")
        self.assertEqual(status, 404)
        self.assertEqual(json.loads(raw)["error"]["code"], server.INVALID_REQUEST)

    def test_invalid_json_is_a_parse_error(self) -> None:
        status, raw = self.request(b"not json")
        self.assertEqual(status, 400)
        self.assertEqual(json.loads(raw)["error"]["code"], server.PARSE_ERROR)

    def test_batch_is_refused(self) -> None:
        status, raw = self.request([{"jsonrpc": "2.0", "id": 1, "method": "ping"}])
        self.assertEqual(status, 400)
        self.assertEqual(json.loads(raw)["error"]["code"], server.INVALID_REQUEST)

    def test_oversized_body_is_refused_before_it_is_read(self) -> None:
        body = b'{"jsonrpc":"2.0","id":1,"method":"ping","pad":"' + b"a" * support.MAX_BYTES
        status, raw = self.request(body)
        self.assertEqual(status, 413)
        self.assertEqual(json.loads(raw)["error"]["code"], server.INVALID_REQUEST)

    def test_the_token_never_reaches_a_log_line(self) -> None:
        with self.assertLogs("agent-facade", level="INFO") as captured:
            self.rpc("tools/list")
        self.assertNotIn(support.TOKEN, "\n".join(captured.output))
        self.assertNotIn(TOKEN_HEADER, "\n".join(captured.output))

    def test_a_facade_without_a_token_refuses_even_a_matching_header(self) -> None:
        facade = server.Facade(
            deployment=self.deployment,
            catalog=self.catalog,
            store=self.store,
            token=None,
            max_body_bytes=support.MAX_BYTES,
        )
        self.assertFalse(facade.authorised(support.TOKEN))
        self.assertFalse(facade.authorised(""))
        result = facade.handle("tools/call", {"name": "sources.describe", "arguments": {}})
        self.assertTrue(result["isError"])
        self.assertEqual(result["structuredContent"]["error"]["code"], "unauthorized")

    def test_token_comparison_is_exact(self) -> None:
        self.assertTrue(self.facade.authorised(support.TOKEN))
        for presented in (support.TOKEN + " ", support.TOKEN[:-1], support.TOKEN.upper(), None, 7):
            with self.subTest(presented=presented):
                self.assertFalse(self.facade.authorised(presented))

    def test_a_catalog_of_the_other_deployment_cannot_be_served(self) -> None:
        with self.assertRaises(ContractError):
            server.Facade(
                deployment=Visibility.GENERAL,
                catalog=sources.Catalog.for_deployment(Visibility.PERSONAL),
                store=self.store,
                token=support.TOKEN,
            )


class StdioTransportTestCase(support.FacadeCase):
    def run_stdio(self, lines: list[str], facade: server.Facade | None = None) -> list[dict]:
        stdin = io.StringIO("\n".join(lines) + "\n")
        stdout = io.StringIO()
        server.serve_stdio(facade or self.facade, stdin=stdin, stdout=stdout)
        self.output = stdout.getvalue()
        return [json.loads(line) for line in self.output.splitlines()]

    def test_every_tool_call_is_refused_without_a_token(self) -> None:
        facade = server.Facade(
            deployment=self.deployment,
            catalog=self.catalog,
            store=self.store,
            token=None,
            max_body_bytes=support.MAX_BYTES,
        )
        calls = [
            json.dumps(
                {
                    "jsonrpc": "2.0",
                    "id": index,
                    "method": "tools/call",
                    "params": {"name": name, "arguments": {}},
                }
            )
            for index, name in enumerate(("sources.describe", "memory.read", "not-a-tool"))
        ]
        responses = self.run_stdio(calls, facade)
        self.assertEqual(len(responses), 3)
        for response in responses:
            with self.subTest(response=response):
                self.assertTrue(response["result"]["isError"])
                self.assertEqual(
                    response["result"]["structuredContent"]["error"]["code"], "unauthorized"
                )

    def test_initialize_still_answers_without_a_token(self) -> None:
        facade = server.Facade(
            deployment=self.deployment,
            catalog=self.catalog,
            store=self.store,
            token=None,
        )
        responses = self.run_stdio(['{"jsonrpc":"2.0","id":1,"method":"initialize"}'], facade)
        self.assertEqual(responses[0]["result"]["serverInfo"]["name"], "agent-facade-personal")

    def test_a_tool_call_works_with_a_token(self) -> None:
        responses = self.run_stdio(
            [
                json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "id": 1,
                        "method": "tools/call",
                        "params": {"name": "sources.read", "arguments": {"source": "notes", "id": "note-1"}},
                    }
                )
            ]
        )
        result = responses[0]["result"]
        self.assertFalse(result["isError"])
        self.assertEqual(result["structuredContent"]["id"], "note-1")

    def test_notifications_and_blank_lines_produce_no_output(self) -> None:
        responses = self.run_stdio(
            [
                '{"jsonrpc":"2.0","method":"notifications/initialized"}',
                "",
                "   ",
                '{"jsonrpc":"2.0","id":9,"method":"ping"}',
            ]
        )
        self.assertEqual([response["id"] for response in responses], [9])

    def test_unknown_method_is_32601(self) -> None:
        responses = self.run_stdio(['{"jsonrpc":"2.0","id":1,"method":"resources/list"}'])
        self.assertEqual(responses[0]["error"]["code"], server.METHOD_NOT_FOUND)

    def test_an_invalid_line_gets_a_parse_error(self) -> None:
        responses = self.run_stdio(["not json"])
        self.assertIsNone(responses[0]["id"])
        self.assertEqual(responses[0]["error"]["code"], server.PARSE_ERROR)

    def test_the_token_is_never_written_to_stdout(self) -> None:
        self.run_stdio(['{"jsonrpc":"2.0","id":1,"method":"tools/list"}'])
        self.assertNotIn(support.TOKEN, self.output)


class TokenConfigurationTestCase(support.FacadeCase):
    def test_environment_token_is_used(self) -> None:
        with mock.patch.dict("os.environ", {"AGENT_FACADE_TOKEN": "from-env"}, clear=False):
            self.assertEqual(cli._token(None), "from-env")

    def test_token_file_wins_and_is_stripped(self) -> None:
        path = Path(self.directory.name) / "token"
        path.write_text("from-file\n", encoding="utf-8")
        with mock.patch.dict("os.environ", {"AGENT_FACADE_TOKEN": "from-env"}, clear=False):
            self.assertEqual(cli._token(str(path)), "from-file")

    def test_an_empty_token_file_is_a_startup_failure(self) -> None:
        path = Path(self.directory.name) / "token"
        path.write_text("\n", encoding="utf-8")
        with self.assertRaises(cli.ConfigError):
            cli._token(str(path))

    def test_an_unreadable_token_file_is_a_startup_failure(self) -> None:
        with self.assertRaises(cli.ConfigError):
            cli._token(str(Path(self.directory.name) / "missing"))

    def test_a_missing_deployment_exits_non_zero(self) -> None:
        with mock.patch.dict("os.environ", {"AGENT_FACADE_DEPLOYMENT": ""}, clear=False):
            self.assertEqual(cli.main(["--transport", "http"]), 2)

    def test_a_non_positive_byte_cap_exits_non_zero(self) -> None:
        self.assertEqual(
            cli.main(
                ["--transport", "http", "--deployment", "personal", "--max-body-bytes", "0"]
            ),
            2,
        )

    def test_environment_flags_fill_the_parser(self) -> None:
        environment = {
            "AGENT_FACADE_TRANSPORT": "http",
            "AGENT_FACADE_DEPLOYMENT": "general",
            "AGENT_FACADE_MEMORY_ROOT": "/tmp/agent-memory",
            "AGENT_FACADE_HOST": "0.0.0.0",
            "AGENT_FACADE_PORT": "19004",
            "AGENT_FACADE_MAX_BODY_BYTES": "1024",
        }
        with mock.patch.dict("os.environ", environment, clear=False):
            args = cli._parser().parse_args([])
        self.assertEqual(args.transport, "http")
        self.assertEqual(args.deployment, "general")
        self.assertEqual(args.memory_root, "/tmp/agent-memory")
        self.assertEqual(args.host, "0.0.0.0")
        self.assertEqual(args.port, 19004)
        self.assertEqual(args.max_body_bytes, 1024)

    def test_the_defaults_are_loopback_and_stdio(self) -> None:
        with mock.patch.dict(
            "os.environ",
            {
                "AGENT_FACADE_TRANSPORT": "",
                "AGENT_FACADE_HOST": "",
                "AGENT_FACADE_PORT": "",
            },
            clear=False,
        ):
            args = cli._parser().parse_args([])
        self.assertEqual(args.transport, "stdio")
        self.assertEqual(args.host, "127.0.0.1")
        self.assertEqual(args.port, 18004)

    def test_build_facade_serves_the_named_deployment(self) -> None:
        with mock.patch.dict(
            "os.environ",
            {"AGENT_FACADE_TOKEN": support.TOKEN, "AGENT_FACADE_TOKEN_FILE": ""},
            clear=False,
        ):
            args = cli._parser().parse_args(
                ["--deployment", "general", "--memory-root", self.directory.name]
            )
            facade = cli.build_facade(args)
        self.assertEqual(facade.deployment, Visibility.GENERAL)
        self.assertEqual(facade.store.profile, memory.PROFILE_BY_DEPLOYMENT[Visibility.GENERAL])
        self.assertTrue(facade.token_configured)


if __name__ == "__main__":
    unittest.main()
