#!/usr/bin/env python3
"""Phase B UI page contracts: router pages registered in main_pages.json;
Import page uses ScanKit default-UI scan + PasteButton security component +
DocumentViewPicker; no CAMERA/READ_PASTEBOARD permission sneaks into
module.json5; NodeDetail masks sensitive keys by default; Index keeps
home-page connection logic and only gains navigation entries + page-show
node-list refresh. Source-level locks in the existing test_import_layer style."""
from __future__ import annotations

import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ETS = ROOT / "entry/src/main/ets"
PAGES = ETS / "pages"
SERVICES = ETS / "services"
MAIN_PAGES = ROOT / "entry/src/main/resources/base/profile/main_pages.json"
MODULE = ROOT / "entry/src/main/module.json5"

NEW_ROUTES = ("pages/Import", "pages/Subscriptions", "pages/Nodes", "pages/NodeDetail")

FORBIDDEN_PERMISSIONS = (
    "ohos.permission.CAMERA",
    "ohos.permission.READ_PASTEBOARD",
    "ohos.permission.READ_MEDIA",
)


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


class RouteRegistration(unittest.TestCase):
    def test_main_pages_registers_all_routes(self) -> None:
        doc = json.loads(read(MAIN_PAGES))
        src = doc.get("src")
        self.assertIsInstance(src, list)
        self.assertEqual(src[0], "pages/Index", "pages/Index must stay the home page")
        for route in NEW_ROUTES:
            self.assertIn(route, src, f"main_pages.json missing route {route}")

    def test_page_files_exist_and_are_entry_components(self) -> None:
        for route in NEW_ROUTES:
            path = PAGES / f"{route.split('/')[-1]}.ets"
            self.assertTrue(path.is_file(), f"missing page file {path}")
            src = read(path)
            self.assertIn("@Entry", src, f"{path.name} missing @Entry")
            self.assertIn("@Component", src, f"{path.name} missing @Component")


class ImportPageContracts(unittest.TestCase):
    def test_scan_uses_scankit_default_ui(self) -> None:
        src = read(PAGES / "Import.ets")
        self.assertIn("scanBarcode.startScanForResult", src)
        self.assertIn("scanCore.ScanType.QR_CODE", src)
        self.assertIn("enableAlbum: true", src)

    def test_scan_cancel_codes_are_silent(self) -> None:
        src = read(PAGES / "Import.ets")
        self.assertIn("1000500002", src, "ScanKit user-cancel code must be handled")
        self.assertIn("20001", src, "picker user-cancel code must be handled")

    def test_album_qr_uses_photoaccesshelper_and_detectbarcode(self) -> None:
        src = read(PAGES / "Import.ets")
        self.assertIn("photoAccessHelper.PhotoViewPicker", src)
        self.assertIn("detectBarcode.decode", src)

    def test_clipboard_read_only_via_pastebutton(self) -> None:
        src = read(PAGES / "Import.ets")
        self.assertIn("PasteButton(", src, "clipboard read must go through PasteButton")
        self.assertIn("PasteButtonOnClickResult.SUCCESS", src)
        # getData must only appear inside the PasteButton-driven handler.
        getdata_lines = [l for l in src.splitlines() if "getData(" in l]
        self.assertTrue(getdata_lines, "expected a pasteboard getData call")
        self.assertIn("readClipboardIntoForm", src)
        handler = re.search(
            r"readClipboardIntoForm\(\).*?\n  \}\n", src, re.DOTALL
        )
        self.assertIsNotNone(handler, "readClipboardIntoForm handler not found")
        for line in getdata_lines:
            self.assertIn(
                line.strip(),
                handler.group(0),
                "pasteboard.getData must live inside the PasteButton handler",
            )

    def test_config_file_import_caps_size_and_uses_document_picker(self) -> None:
        src = read(PAGES / "Import.ets")
        self.assertIn("picker.DocumentViewPicker", src)
        self.assertIn("fileSuffixFilters", src)
        self.assertIn("MAX_CONFIG_FILE_BYTES", src)

    def test_import_goes_through_preview_then_commit(self) -> None:
        src = read(PAGES / "Import.ets")
        self.assertIn("SubscriptionManager.importFromText", src)
        self.assertIn("SubscriptionManager.commitImport", src)
        self.assertIn("已添加", src)
        self.assertIn("跳过", src)
        self.assertIn("确认添加", src)
        self.assertIn("取消", src)
        self.assertIn("添加为订阅", src)

    def test_manual_form_builds_outbound_and_validates(self) -> None:
        src = read(PAGES / "Import.ets")
        self.assertIn("buildManualOutbound", src)
        self.assertIn("validateManual", src)
        self.assertIn("SOURCE_MANUAL", src)


class SubscriptionsPageContracts(unittest.TestCase):
    def test_mutations_via_stores(self) -> None:
        src = read(PAGES / "Subscriptions.ets")
        for api in (
            "SubscriptionStore.add",
            "SubscriptionStore.update",
            "SubscriptionStore.remove",
            "SubscriptionManager.updateSubscription",
            "SubscriptionManager.validateSubscriptionUrl",
        ):
            self.assertIn(api, src, f"Subscriptions.ets missing {api}")

    def test_interval_options_and_default(self) -> None:
        src = read(PAGES / "Subscriptions.ets")
        self.assertRegex(src, r"INTERVAL_OPTIONS.*=.*\[2, 6, 12, 24\]")
        self.assertIn("autoUpdate", src)

    def test_userinfo_and_error_display(self) -> None:
        src = read(PAGES / "Subscriptions.ets")
        self.assertIn("已用", src)
        self.assertIn("长期", src)
        self.assertIn("lastError", src)
        self.assertIn("maskUrlMiddle", src)


class NodePagesContracts(unittest.TestCase):
    def test_nodes_page_features(self) -> None:
        src = read(PAGES / "Nodes.ets")
        for feature in (
            "NodeStore.toggleFavorite",
            "NodeStore.rename",
            "NodeStore.setGroup",
            "NodeStore.removeNodes",
            "NodeStore.sortByLatency",
            "NodeStore.sortFavoriteFirst",
            "NodeStore.displayName",
        ):
            self.assertIn(feature, src, f"Nodes.ets missing {feature}")

    def test_node_detail_masks_sensitive_keys(self) -> None:
        fields_src = read(SERVICES / "NodeDetailFields.ets")
        self.assertIn("sensitive: boolean", fields_src)
        # 密码 / UUID / 密钥类字段必须标 sensitive=true。
        sensitive_block = re.findall(
            r"pushField\(fields, '[^']+', [^;]+?, (true|false)\)", fields_src
        )
        self.assertIn("true", sensitive_block, "no sensitive field flagged")
        page_src = read(PAGES / "NodeDetail.ets")
        self.assertIn("MASKED_VALUE", page_src)
        self.assertIn("••••••••", page_src)
        self.assertIn("NodeStore.maskEndpointAddress", page_src)
        self.assertIn("复制内容含凭据", page_src)

    def test_node_detail_sections(self) -> None:
        fields_src = read(SERVICES / "NodeDetailFields.ets")
        for section in ("基本", "传输", "安全"):
            self.assertIn(f"'{section}'", fields_src)


class PermissionLocks(unittest.TestCase):
    def test_no_new_permissions_in_module(self) -> None:
        src = read(MODULE)
        for perm in FORBIDDEN_PERMISSIONS:
            self.assertNotIn(perm, src, f"{perm} must not be declared")

    def test_module_permissions_unchanged_set(self) -> None:
        src = read(MODULE)
        granted = set(re.findall(r'"name":\s*"(ohos\.permission\.[^"]+)"', src))
        self.assertEqual(
            granted,
            {
                "ohos.permission.INTERNET",
                "ohos.permission.GET_NETWORK_INFO",
                "ohos.permission.KEEP_BACKGROUND_RUNNING",
            },
        )


class IndexIntegration(unittest.TestCase):
    def test_index_nav_entries_and_refresh(self) -> None:
        src = read(PAGES / "Index.ets")
        self.assertIn(".tabBar('节点')", src)
        self.assertIn("Nodes({ embedded: true })", src)
        nodes = read(PAGES / "Nodes.ets")
        for route in ("pages/Import", "pages/Subscriptions"):
            self.assertIn(route, nodes, f"Nodes missing navigation to {route}")
        self.assertIn("onPageShow", src)
        self.assertIn("StatusStore.readNodes", src)

    def test_index_connection_logic_untouched(self) -> None:
        src = read(PAGES / "Index.ets")
        for anchor in (
            "CONNECTION_CONTROLLER.start",
            "CONNECTION_CONTROLLER.stop",
            "tcpConnectCanary",
            "BACKGROUND_KEEP_ALIVE.ensure",
        ):
            self.assertIn(anchor, src, f"Index lost {anchor}")

    def test_protected_files_not_modified_by_phase_b(self) -> None:
        """DO-NOT-TOUCH list from the Phase B brief: these files must not import
        or reference any of the new pages."""
        protected = (
            ETS / "vpn/TunnelVpnAbility.ets",
            ETS / "core/XrayRuntime.ets",
            ETS / "net/SplitRouter.ets",
            SERVICES / "ConnectionController.ets",
        )
        for path in protected:
            if not path.is_file():
                continue
            src = read(path)
            for route in NEW_ROUTES:
                self.assertNotIn(route, src, f"{path.name} must not reference {route}")


if __name__ == "__main__":
    unittest.main()
