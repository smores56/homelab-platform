"""The deployment split is a table, and one table cannot name the other's sources.

These assertions are about the registry and the catalog, not about a handler
string comparison: a personal facade has no repos or books adapter to consult,
and a catalog refuses to be built from an adapter of another visibility.
"""

from __future__ import annotations

import unittest

from data_plane.errors import ContractError, ValidationError
from data_plane.model import EffectClass, Visibility

from apps.agent_facade import server, sources
from apps.agent_facade.tests import support

PERSONAL = (
    "notes",
    "tasks",
    "mail",
    "calendar",
    "finance",
    "brave",
    "photos",
    "music",
    "workspace",
)
GENERAL = ("repos", "books")


class RegistryTestCase(unittest.TestCase):
    def test_deployments_are_exactly_two(self) -> None:
        self.assertEqual(sources.DEPLOYMENTS, (Visibility.PERSONAL, Visibility.GENERAL))
        self.assertEqual(set(sources.SOURCES_BY_DEPLOYMENT), set(sources.DEPLOYMENTS))

    def test_personal_table_holds_personal_sources_only(self) -> None:
        table = sources.SOURCES_BY_DEPLOYMENT[Visibility.PERSONAL]
        self.assertEqual(tuple(table), PERSONAL)
        for general in GENERAL:
            self.assertNotIn(general, table)

    def test_general_table_holds_general_sources_only(self) -> None:
        table = sources.SOURCES_BY_DEPLOYMENT[Visibility.GENERAL]
        self.assertEqual(tuple(table), GENERAL)
        for personal in PERSONAL:
            self.assertNotIn(personal, table)

    def test_tables_are_disjoint(self) -> None:
        personal = set(sources.SOURCES_BY_DEPLOYMENT[Visibility.PERSONAL])
        general = set(sources.SOURCES_BY_DEPLOYMENT[Visibility.GENERAL])
        self.assertFalse(personal & general)

    def test_every_adapter_declares_its_table_visibility(self) -> None:
        for deployment, table in sources.SOURCES_BY_DEPLOYMENT.items():
            for name, adapter in table.items():
                with self.subTest(deployment=deployment.value, source=name):
                    self.assertEqual(adapter.contract.visibility, deployment)
                    self.assertEqual(adapter.contract.source_id, name)

    def test_tables_are_immutable(self) -> None:
        with self.assertRaises(TypeError):
            sources.SOURCES_BY_DEPLOYMENT[Visibility.PERSONAL]["books"] = object()  # type: ignore[index]

    def test_deployment_parser_refuses_anything_else(self) -> None:
        self.assertEqual(sources.deployment("personal"), Visibility.PERSONAL)
        self.assertEqual(sources.deployment("general"), Visibility.GENERAL)
        for name in ("infrastructure", "", None, 1, "Personal"):
            with self.subTest(name=name):
                with self.assertRaises(ContractError):
                    sources.deployment(name)


class CatalogTestCase(unittest.TestCase):
    def test_personal_catalog_refuses_general_sources(self) -> None:
        catalog = sources.Catalog.for_deployment(Visibility.PERSONAL)
        for name in GENERAL:
            with self.subTest(source=name):
                with self.assertRaises(sources.UnknownSource):
                    catalog.adapter(name)

    def test_general_catalog_refuses_personal_sources(self) -> None:
        catalog = sources.Catalog.for_deployment(Visibility.GENERAL)
        for name in PERSONAL:
            with self.subTest(source=name):
                with self.assertRaises(sources.UnknownSource):
                    catalog.adapter(name)

    def test_personal_catalog_cannot_be_built_from_a_general_adapter(self) -> None:
        general = sources.SOURCES_BY_DEPLOYMENT[Visibility.GENERAL]
        with self.assertRaises(ContractError):
            sources.Catalog(deployment=Visibility.PERSONAL, adapters=general)
        with self.assertRaises(ContractError):
            sources.Catalog(
                deployment=Visibility.GENERAL,
                adapters={**general, "notes": general["books"]},
            )

    def test_catalog_refuses_a_misaddressed_entry(self) -> None:
        personal = sources.SOURCES_BY_DEPLOYMENT[Visibility.PERSONAL]
        with self.assertRaises(ContractError):
            sources.Catalog(
                deployment=Visibility.PERSONAL,
                adapters={"notes": personal["mail"]},
            )

    def test_catalog_refuses_infrastructure(self) -> None:
        with self.assertRaises(ContractError):
            sources.Catalog.for_deployment(Visibility.INFRASTRUCTURE)

    def test_describe_reports_name_kind_and_capabilities(self) -> None:
        descriptions = {
            description.name: description
            for description in sources.Catalog.for_deployment(Visibility.PERSONAL).describe()
        }
        self.assertEqual(set(descriptions), set(PERSONAL))
        self.assertEqual(descriptions["notes"].kind, "notes")
        self.assertTrue(descriptions["notes"].read)
        self.assertTrue(descriptions["notes"].search)
        # The web search index is read through hits, never records.
        self.assertFalse(descriptions["brave"].read)
        self.assertTrue(descriptions["brave"].search)

    def test_capabilities_match_the_contract(self) -> None:
        catalog = sources.Catalog.for_deployment(Visibility.GENERAL)
        for description in catalog.describe():
            contract = catalog.adapter(description.name).contract
            declared = {capability.effect for capability in contract.capabilities}
            with self.subTest(source=description.name):
                self.assertEqual(description.read, EffectClass.READ in declared)
                self.assertEqual(description.search, EffectClass.SEARCH in declared)


class FixtureAdapterTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.personal = sources.Catalog.for_deployment(Visibility.PERSONAL)
        self.general = sources.Catalog.for_deployment(Visibility.GENERAL)

    def test_read_returns_one_record_with_provenance(self) -> None:
        record = self.personal.read("mail", "mail-1")
        self.assertEqual(record.source, "mail")
        self.assertEqual(record.id, "mail-1")
        self.assertEqual(record.title, "Boiler inspection")
        self.assertEqual(record.provenance["source_id"], "mail/mail-1")
        self.assertEqual(record.revision, "1")

    def test_unknown_record_is_refused(self) -> None:
        with self.assertRaises(sources.SourceNotFound):
            self.personal.read("notes", "note-404")

    def test_search_only_source_refuses_a_record_read(self) -> None:
        with self.assertRaises(sources.SourceUnsupported):
            self.personal.read("brave", "web-1")

    def test_search_returns_hits_without_bodies(self) -> None:
        hits = self.personal.search("mail", "boiler", 20)
        self.assertEqual([hit.id for hit in hits], ["mail-1"])
        payload = hits[0].as_dict()
        self.assertEqual(set(payload), {"id", "title", "snippet"})
        self.assertNotIn("body", payload)
        self.assertNotIn("provenance", payload)
        self.assertIn("boiler", payload["snippet"].casefold())

    def test_search_requires_every_word(self) -> None:
        self.assertEqual(self.personal.search("mail", "boiler kettle", 20), ())
        self.assertEqual(len(self.personal.search("mail", "boiler inspection", 20)), 1)

    def test_search_is_bounded_by_the_limit(self) -> None:
        self.assertEqual(len(self.personal.search("notes", "a", 20)), 2)
        self.assertEqual(len(self.personal.search("notes", "a", 1)), 1)

    def test_search_is_deterministic(self) -> None:
        first = self.personal.search("notes", "the", 20)
        second = self.personal.search("notes", "the", 20)
        self.assertEqual(first, second)

    def test_general_sources_are_searchable_from_general_only(self) -> None:
        hits = self.general.search("books", "dune", 20)
        self.assertEqual([hit.id for hit in hits], ["book-2"])
        with self.assertRaises(sources.UnknownSource):
            self.personal.search("books", "dune", 20)

    def test_search_one_word_is_required(self) -> None:
        with self.assertRaises(ValidationError):
            self.personal.search("notes", "   ", 20)


class FacadeSplitTestCase(support.FacadeCase):
    """The same split seen through tool calls, not only through the registry."""

    def test_describe_lists_only_this_deployment(self) -> None:
        result = self.call("sources.describe")
        self.assertEqual(result["deployment"], "personal")
        self.assertEqual([item["name"] for item in result["sources"]], list(PERSONAL))

    def test_reading_a_general_source_is_refused(self) -> None:
        error = self.refusal("sources.read", {"source": "repos", "id": "repo-1"})
        self.assertEqual(error["code"], "unknown_source")

    def test_searching_a_general_source_is_refused(self) -> None:
        error = self.refusal("sources.search", {"source": "books", "query": "dune"})
        self.assertEqual(error["code"], "unknown_source")

    def test_body_cap_truncation_is_flagged(self) -> None:
        clipped = server.Facade(
            deployment=self.deployment,
            catalog=self.catalog,
            store=self.store,
            token=support.TOKEN,
            max_body_bytes=16,
        )
        content = clipped.handle(
            "tools/call",
            {"name": "sources.read", "arguments": {"source": "notes", "id": "note-1"}},
        )["structuredContent"]
        self.assertTrue(content["truncated"])
        self.assertLessEqual(len(content["body"].encode("utf-8")), 16)
        self.assertTrue(content["body"].startswith("Buy milk"))

    def test_a_short_body_is_not_flagged_as_truncated(self) -> None:
        content = self.call("sources.read", {"source": "notes", "id": "note-1"})
        self.assertFalse(content["truncated"])
        self.assertEqual(content["body"], "Buy milk, eggs and coffee before Friday.")
        self.assertEqual(
            set(content),
            {"id", "source", "title", "body", "provenance", "revision", "truncated"},
        )


class GeneralFacadeTestCase(support.FacadeCase):
    deployment = Visibility.GENERAL

    def test_describe_lists_only_general_sources(self) -> None:
        result = self.call("sources.describe")
        self.assertEqual(result["deployment"], "general")
        self.assertEqual([item["name"] for item in result["sources"]], list(GENERAL))

    def test_personal_sources_are_unreachable(self) -> None:
        for name in ("mail", "notes", "brave"):
            with self.subTest(source=name):
                error = self.refusal("sources.read", {"source": name, "id": "mail-1"})
                self.assertEqual(error["code"], "unknown_source")


if __name__ == "__main__":
    unittest.main()
