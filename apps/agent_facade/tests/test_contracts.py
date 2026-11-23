"""The typed operation set refuses what it was not asked to represent.

Every assertion here is about a refusal: an unknown tool, an unknown field, a
wrong type, an over-long argument, an oversized value, a negative or oversized
limit. Nothing in the suite touches a network or a credential.
"""

from __future__ import annotations

import unittest

from data_plane.errors import ValidationError

from apps.agent_facade import contracts
from apps.agent_facade.tests import support

LIMITS = (0, -1, 51, 1000, "5", 1.5, True, {}, [20])


class ToolSetTestCase(unittest.TestCase):
    def test_tool_names_are_the_typed_operation_set(self) -> None:
        self.assertEqual(
            contracts.TOOL_NAMES,
            (
                "sources.describe",
                "sources.read",
                "sources.search",
                "memory.read",
                "memory.write",
                "memory.search",
                "memory.rebuild",
            ),
        )

    def test_no_operation_is_a_generic_passthrough(self) -> None:
        # A name that would address a path, a query, a URL or a command is not
        # in the set, so there is nothing for such an argument to be passed to.
        for name in ("fs.read", "sql.query", "http.get", "shell.run", "sources.delete"):
            with self.subTest(name=name):
                with self.assertRaises(contracts.UnknownTool):
                    contracts.parse_call(name, {})

    def test_schemas_refuse_unknown_fields(self) -> None:
        for spec in (*contracts.TOOL_SPECS, contracts.SHELL_TOOL):
            with self.subTest(tool=spec.name):
                self.assertEqual(spec.input_schema["type"], "object")
                self.assertFalse(spec.input_schema["additionalProperties"])
                self.assertTrue(spec.as_tool()["description"])

    def test_unknown_tool_is_refused(self) -> None:
        with self.assertRaises(contracts.UnknownTool):
            contracts.parse_call("memory.delete", {"key": "note"})

    def test_non_string_tool_name_is_refused(self) -> None:
        for name in (None, 7, {"name": "memory.read"}):
            with self.subTest(name=name):
                with self.assertRaises(contracts.UnknownTool):
                    contracts.parse_call(name, {})

    def test_unknown_argument_is_refused_for_every_tool(self) -> None:
        cases = {
            "sources.describe": {},
            "sources.read": {"source": "notes", "id": "note-1"},
            "sources.search": {"source": "notes", "query": "milk"},
            "memory.read": {"key": "note"},
            "memory.write": {"key": "note", "value": "v", "provenance": support.PROVENANCE},
            "memory.search": {"query": "milk"},
            "memory.rebuild": {},
        }
        for name, arguments in cases.items():
            with self.subTest(tool=name):
                with self.assertRaises(ValidationError):
                    contracts.parse_call(name, {**arguments, "extra": True})

    def test_arguments_must_be_an_object(self) -> None:
        for arguments in ("{}", [1], 3):
            with self.subTest(arguments=arguments):
                with self.assertRaises(ValidationError):
                    contracts.parse_call("sources.describe", arguments)

    def test_non_string_arguments_are_refused(self) -> None:
        cases = (
            ("sources.read", {"source": 1, "id": "note-1"}),
            ("sources.read", {"source": "notes", "id": ["note-1"]}),
            ("sources.search", {"source": "notes", "query": {}}),
            ("sources.search", {"source": "notes", "query": None}),
            ("memory.read", {"key": False}),
            ("memory.write", {"key": "note", "value": 5, "provenance": support.PROVENANCE}),
            ("memory.search", {"query": ["milk"]}),
        )
        for name, arguments in cases:
            with self.subTest(tool=name, arguments=arguments):
                with self.assertRaises(ValidationError):
                    contracts.parse_call(name, arguments)

    def test_missing_required_arguments_are_refused(self) -> None:
        cases = (
            ("sources.read", {"source": "notes"}),
            ("sources.search", {"query": "milk"}),
            ("memory.read", {}),
            ("memory.write", {"key": "note", "value": "v"}),
            ("memory.search", {}),
        )
        for name, arguments in cases:
            with self.subTest(tool=name):
                with self.assertRaises(ValidationError):
                    contracts.parse_call(name, arguments)

    def test_identifier_arguments_must_be_one_path_segment(self) -> None:
        for value in ("../etc/passwd", "note/1", "note.1", "", " ", "-note", "note\x00"):
            with self.subTest(value=value):
                with self.assertRaises(ValidationError):
                    contracts.parse_call("memory.read", {"key": value})

    def test_over_long_arguments_are_refused(self) -> None:
        with self.assertRaises(ValidationError):
            contracts.parse_call("sources.search", {"source": "notes", "query": "a" * 513})
        with self.assertRaises(ValidationError):
            contracts.parse_call("memory.read", {"key": "k" * 129})
        with self.assertRaises(ValidationError):
            contracts.parse_call("sources.read", {"source": "s" * 65, "id": "note-1"})


class ShellContractTestCase(unittest.TestCase):
    """``shell.run``: one command, and the served set decides whether it exists."""

    def test_the_shell_tool_is_not_in_the_base_set(self) -> None:
        self.assertNotIn("shell.run", contracts.TOOL_NAMES)
        self.assertNotIn(contracts.SHELL_TOOL, contracts.TOOL_SPECS)
        with self.assertRaises(contracts.UnknownTool):
            contracts.parse_call("shell.run", {"command": "ls"})

    def test_the_schema_offers_only_a_command(self) -> None:
        schema = contracts.SHELL_TOOL.input_schema
        self.assertEqual(contracts.SHELL_TOOL.name, "shell.run")
        self.assertEqual(list(schema["properties"]), ["command"])
        self.assertEqual(schema["required"], ["command"])
        self.assertFalse(schema["additionalProperties"])
        self.assertEqual(
            schema["properties"]["command"]["maxLength"], contracts.MAX_COMMAND_CHARS
        )
        for promise in ("unsupervised", "general", "capped"):
            self.assertIn(promise, contracts.SHELL_TOOL.description)

    def test_a_command_is_parsed_verbatim_with_tabs_and_newlines(self) -> None:
        command = "printf 'a'\n\tprintf 'b'"
        operation = contracts.parse_call(
            "shell.run", {"command": command}, allow_shell=True
        )
        self.assertEqual(operation, contracts.ShellRun(command=command))
        self.assertEqual(operation.command, command)

    def test_a_refused_command_never_becomes_an_operation(self) -> None:
        for arguments in (
            {"command": "ls\u0000"},
            {"command": "ls\u0007"},
            {"command": "ls\r"},
            {"command": "ls\u007f"},
            {"command": ""},
            {"command": "   "},
            {"command": 7},
            {"command": ["ls"]},
            {"command": "x" * (contracts.MAX_COMMAND_CHARS + 1)},
            {"command": "ls", "class": "personal"},
            {"command": "ls", "image": "alpine"},
            {},
        ):
            with self.subTest(arguments=arguments):
                with self.assertRaises(ValidationError):
                    contracts.parse_call("shell.run", arguments, allow_shell=True)

    def test_the_maximum_command_length_is_accepted(self) -> None:
        command = "x" * contracts.MAX_COMMAND_CHARS
        self.assertEqual(
            contracts.parse_call("shell.run", {"command": command}, allow_shell=True).command,
            command,
        )


class LimitTestCase(unittest.TestCase):
    def test_omitted_limit_defaults(self) -> None:
        operation = contracts.parse_call("memory.search", {"query": "milk"})
        self.assertEqual(operation.limit, contracts.DEFAULT_SEARCH_LIMIT)

    def test_maximum_limit_is_accepted(self) -> None:
        operation = contracts.parse_call("sources.search", {"source": "notes", "query": "milk", "limit": 50})
        self.assertEqual(operation.limit, 50)

    def test_bad_limits_are_refused(self) -> None:
        for limit in LIMITS:
            with self.subTest(limit=limit):
                with self.assertRaises(ValidationError):
                    contracts.parse_call(
                        "sources.search", {"source": "notes", "query": "milk", "limit": limit}
                    )


class MemoryWriteTestCase(unittest.TestCase):
    def test_value_over_the_cap_is_refused_not_clipped(self) -> None:
        with self.assertRaises(ValidationError):
            contracts.parse_call(
                "memory.write",
                {"key": "note", "value": "a" * 65, "provenance": support.PROVENANCE},
                max_bytes=64,
            )

    def test_value_at_the_cap_is_accepted(self) -> None:
        operation = contracts.parse_call(
            "memory.write",
            {"key": "note", "value": "a" * 64, "provenance": support.PROVENANCE},
            max_bytes=64,
        )
        self.assertEqual(len(operation.value), 64)

    def test_provenance_is_required(self) -> None:
        with self.assertRaises(ValidationError):
            contracts.parse_call("memory.write", {"key": "note", "value": "v"})

    def test_provenance_shape_is_enforced(self) -> None:
        cases = (
            "notes/note-1",
            {"source_id": "notes/1", "revision": "1"},
            {"source_id": "notes/1", "revision": "1", "captured_at": "x", "secret": "y"},
            {"source_id": 1, "revision": "1", "captured_at": "x"},
            {"source_id": "notes/1", "revision": "1", "captured_at": ""},
        )
        for provenance in cases:
            with self.subTest(provenance=provenance):
                with self.assertRaises(ValidationError):
                    contracts.parse_call(
                        "memory.write", {"key": "note", "value": "v", "provenance": provenance}
                    )

    def test_tags_are_bounded_and_typed(self) -> None:
        for tags in ("preference", ["a"] * 17, [1], [""]):
            with self.subTest(tags=tags):
                with self.assertRaises(ValidationError):
                    contracts.parse_call(
                        "memory.write",
                        {"key": "note", "value": "v", "tags": tags, "provenance": support.PROVENANCE},
                    )

    def test_provenance_is_immutable(self) -> None:
        operation = contracts.parse_call(
            "memory.write", {"key": "note", "value": "v", "provenance": support.PROVENANCE}
        )
        with self.assertRaises(TypeError):
            operation.provenance["source_id"] = "other"  # type: ignore[index]


class RenderingTestCase(unittest.TestCase):
    def test_body_clipping_flags_truncation(self) -> None:
        body = "a" * 32
        self.assertEqual(contracts.clip_body(body, 32), (body, False))
        clipped, truncated = contracts.clip_body(body, 16)
        self.assertTrue(truncated)
        self.assertEqual(len(clipped), 16)

    def test_body_clipping_stays_on_a_character_boundary(self) -> None:
        clipped, truncated = contracts.clip_body("é" * 8, 5)
        self.assertTrue(truncated)
        self.assertEqual(clipped, "éé")
        self.assertEqual(clipped.encode("utf-8"), b"\xc3\xa9\xc3\xa9")

    def test_snippet_is_one_line_and_bounded(self) -> None:
        text = "line one\nline two\n" + "x" * 400
        excerpt = contracts.snippet(text, "two", width=40)
        self.assertNotIn("\n", excerpt)
        self.assertLessEqual(len(excerpt), 42)

    def test_search_expression_quotes_caller_words(self) -> None:
        expression = contracts.search_expression('tea OR "x" -y*')
        self.assertEqual(expression, '"tea" AND "OR" AND "x" AND "y"')

    def test_query_without_words_is_refused(self) -> None:
        for query in ("   ", "---", "!?"):
            with self.subTest(query=query):
                with self.assertRaises(ValidationError):
                    contracts.search_expression(query)


if __name__ == "__main__":
    unittest.main()
