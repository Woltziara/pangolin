#!/usr/bin/env python3
"""Phase C2 contracts: user routing rules (user-rules.json) — payload threading,
injection ORDER in the Xray rule chain (safety rules < user rules < service/geo
rules), domain validation, group→leg mapping, Rules page anchors, cap=200.

Two verification layers:
1. Source-level locks in the test_import_layer / test_settings_modes style.
2. A Python mirror of the payload→rule-chain shape (XrayRuntime imports the
   native .so and cannot go through node-runner tsc). The pure mapping logic
   itself (core/UserRuleMap.ets) IS compiled and truth-tested by
   tests/node-runner/userrule.test.mjs — the mirror here only locks the
   XrayRuntime assembly shape (order, payload field names)."""
from __future__ import annotations

import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ETS = ROOT / "entry/src/main/ets"
XRAY = ETS / "core/XrayRuntime.ets"
RULE_MAP = ETS / "core/UserRuleMap.ets"
RULE_STORE = ETS / "services/UserRuleStore.ets"
CATALOG = ETS / "services/NodeCatalog.ets"
SPLIT = ETS / "services/SplitRouter.ets"
RULES_PAGE = ETS / "pages/Rules.ets"
INDEX = ETS / "pages/Index.ets"
MAIN_PAGES = ROOT / "entry/src/main/resources/base/profile/main_pages.json"
NODE_RUNNER_BUILD = ROOT / "tests/node-runner/build.mjs"
NODE_RUNNER_PKG = ROOT / "tests/node-runner/package.json"
NODE_RUNNER_TEST = ROOT / "tests/node-runner/userrule.test.mjs"

RULE_CHAIN = ("dnsHijack, dummyV6, privateRule, quicRule, youtubeRule, "
              "proxyProbeRule, cnDomainRule, cnIpRule, proxyRule")
GLOBAL_CHAIN = ("dnsHijack, dummyV6, privateRule, quicRule, youtubeRule, "
                "proxyProbeRule, proxyRule")


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


# ---------------------------------------------------------------------------
# Python mirrors (must match core/UserRuleMap.ets and the XrayRuntime assembly)
# ---------------------------------------------------------------------------

LABEL = re.compile(r"[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?")
TLD = re.compile(r"[a-z]{2,}")
IP_LIKE = re.compile(r"[0-9.:]+")


def normalize_domain_input(raw: str) -> tuple[bool, str, str]:
    """Mirror of UserRuleMap.normalizeDomainInput → (ok, normalized, error)."""
    s = raw.strip()
    if not s:
        return False, "", "请输入域名"
    if len(s) > 253:
        return False, "", "域名过长"
    if s.startswith("regexp:"):
        expr = s[len("regexp:"):].strip()
        if not expr:
            return False, "", "regexp: 后面需要跟上正则表达式"
        return True, f"regexp:{expr}", ""
    if "/" in s or IP_LIKE.fullmatch(s):
        return False, "", "暂只支持域名规则"
    if ":" in s:
        return False, "", "只支持 regexp: 前缀的高级写法"
    bare = s[2:] if s.startswith("*.") else s
    bare = bare.lower()
    if "." not in bare:
        return False, "", "请输入完整域名（如 example.com）"
    labels = bare.split(".")
    for label in labels:
        if not LABEL.fullmatch(label):
            return False, "", "域名格式不正确"
    if not TLD.fullmatch(labels[-1]):
        return False, "", "域名格式不正确"
    return True, bare, ""


def xray_domain_of(normalized: str) -> str:
    return normalized if normalized.startswith("regexp:") else f"domain:{normalized}"


def build_user_routing_rules(routes: list[dict], yt_group: str,
                             us_group: str) -> list[dict]:
    """Mirror of UserRuleMap.buildUserRoutingRules (incl. cap=200)."""
    rules = []
    for route in routes:
        if len(rules) >= 200:
            break
        domain = route.get("domain", "")
        if not domain:
            continue
        action = route.get("action", "")
        if action == "direct":
            tag = "direct"
        elif action == "proxy":
            tag = "proxy"
        elif action == "group":
            group = route.get("groupTag", "")
            if group and group == us_group:
                tag = "proxy"
            elif group and group == yt_group:
                tag = "proxy-yt"
            else:
                continue
        else:
            continue
        rules.append({"type": "field", "domain": [xray_domain_of(domain)],
                      "outboundTag": tag})
    return rules


def final_rule_chain(mode: str, user_rules: list[str]) -> list[str]:
    """Mirror of the XrayRuntime mode branches + withUserRules splice."""
    if mode == "direct":
        # 全部直连：用户规则不注入
        return ["dnsHijack", "dummyV6", "privateRule", "directRule"]
    chain = (RULE_CHAIN.split(", ") if mode == "rule"
             else GLOBAL_CHAIN.split(", "))
    if not user_rules:
        return chain
    return chain[:3] + user_rules + chain[3:]


class DomainValidationMirror(unittest.TestCase):
    def test_bare_and_wildcard_and_case(self) -> None:
        self.assertEqual(normalize_domain_input("example.com"),
                         (True, "example.com", ""))
        self.assertEqual(normalize_domain_input("  EXAMPLE.com "),
                         (True, "example.com", ""))
        self.assertEqual(normalize_domain_input("*.Example.COM"),
                         (True, "example.com", ""))
        self.assertEqual(normalize_domain_input("sub.a-b.example-cdn.co.uk"),
                         (True, "sub.a-b.example-cdn.co.uk", ""))

    def test_regexp_passthrough(self) -> None:
        ok, normalized, _ = normalize_domain_input(r"regexp:.*\.googlevideo\.com$")
        self.assertTrue(ok)
        self.assertEqual(normalized, r"regexp:.*\.googlevideo\.com$")
        ok, _, error = normalize_domain_input("regexp:")
        self.assertFalse(ok)
        self.assertIn("regexp", error)

    def test_ip_and_cidr_rejected_with_chinese_hint(self) -> None:
        for value in ("1.2.3.4", "10.0.0.0/8", "192.168.1.1/24", "::1"):
            ok, _, error = normalize_domain_input(value)
            self.assertFalse(ok, value)
            self.assertEqual(error, "暂只支持域名规则", value)

    def test_garbage_rejected(self) -> None:
        for value in ("", "   ", "exa mple.com", "-bad.com", "localhost",
                      "example.c", "a..com", ".example.com", "example.com."):
            ok, _, _ = normalize_domain_input(value)
            self.assertFalse(ok, value)
        ok, _, error = normalize_domain_input("domain:example.com")
        self.assertFalse(ok)
        self.assertEqual(error, "只支持 regexp: 前缀的高级写法")

    def test_source_locks_for_validation(self) -> None:
        src = read(RULE_MAP)
        self.assertIn("暂只支持域名规则", src)
        self.assertIn("regexp:", src)
        self.assertIn("只支持 regexp: 前缀的高级写法", src)
        self.assertIn("请输入完整域名（如 example.com）", src)


class RuleChainInjectionContract(unittest.TestCase):
    def test_injection_order_source_anchors(self) -> None:
        src = read(XRAY)
        # both mode chains keep their Phase C literals verbatim
        self.assertIn(RULE_CHAIN, src)
        self.assertIn(GLOBAL_CHAIN, src)
        # splice point: safety three (dnsHijack/dummyV6/privateRule) stay ahead
        self.assertIn("chain.slice(0, 3)", src)
        self.assertIn("head.concat(userRules).concat(tail)", src)
        # applied in exactly the rule and global branches, not direct
        self.assertEqual(src.count("routing['rules'] = withUserRules(chain, userRuleRoutes)"), 2)
        direct_branch = src.split("mode === 'direct'")[1].split("} else {")[0]
        self.assertNotIn("withUserRules", direct_branch)
        self.assertIn("dnsHijack, dummyV6, privateRule, directRule", src)

    def test_byte_identical_when_no_user_rules(self) -> None:
        src = read(XRAY)
        # withUserRules early-return keeps the chain untouched
        self.assertIn("if (userRules.length === 0)", src)
        helper = src.split("function withUserRules")[1].split("function ")[0]
        self.assertIn("return chain", helper)
        # mirror: empty user rules = today's chains, in both modes
        self.assertEqual(final_rule_chain("rule", []), RULE_CHAIN.split(", "))
        self.assertEqual(final_rule_chain("global", []), GLOBAL_CHAIN.split(", "))
        self.assertEqual(final_rule_chain("direct", ["userRule"]),
                         ["dnsHijack", "dummyV6", "privateRule", "directRule"])

    def test_user_rules_sit_between_safety_and_service_rules(self) -> None:
        chain = final_rule_chain("rule", ["userRule1", "userRule2"])
        self.assertEqual(chain[:3], ["dnsHijack", "dummyV6", "privateRule"])
        self.assertEqual(chain[3:5], ["userRule1", "userRule2"])
        self.assertLess(chain.index("privateRule"), chain.index("userRule1"))
        self.assertLess(chain.index("userRule2"), chain.index("quicRule"))
        self.assertLess(chain.index("userRule2"), chain.index("cnDomainRule"))

    def test_payload_read_anchors(self) -> None:
        src = read(XRAY)
        self.assertIn("parseUserRuleRoutes(parsed['userRules'])", src)
        self.assertIn("asString(parsed['ytGroup'], '')", src)
        self.assertIn("asString(parsed['usGroup'], '')", src)
        self.assertIn("buildUserRoutingRules", src)


class PayloadThreadingContract(unittest.TestCase):
    def test_catalog_emits_fields_only_when_rules_exist(self) -> None:
        src = read(CATALOG)
        self.assertIn("rec['userRules'] = arr", src)
        self.assertIn("rec['ytGroup'] = ytGroup", src)
        self.assertIn("rec['usGroup'] = usGroup", src)
        attach = src.split("function attachUserRules")[1]
        self.assertIn("if (userRules.length === 0)", attach.split("}")[0])
        # existing call sites keep compiling: new params are optional trailing
        self.assertIn("userRules: Array<UserRuleRoute> = []", src)

    def test_split_router_threads_rules_and_groups(self) -> None:
        src = read(SPLIT)
        self.assertIn("UserRuleStore.enabledRoutes(context)", src)
        self.assertIn("settings.routeMode === 'direct' || userRules.length > 0", src)
        self.assertIn("groups.get(yt.name)", src)
        self.assertIn("groups.get(us.name)", src)
        # default path (no rules, rule mode) still goes through applySplit
        self.assertIn("buildSplitOutboundPayload(yt, us, yt2, us2", src)
        # manual path passes the single node's group and failover backup to both legs
        manual = src.split("export function prepareManualPlan")[1].split("export function")[0]
        self.assertIn("buildSingleOutboundPayload(rec, settings.routeMode, userRules, nodeGroup, backup)", manual)

    def test_fixture_payload_group_leg_mapping(self) -> None:
        """Fixture v=3 payload with userRules → mirror emits expected Xray rules."""
        payload = {
            "v": 3,
            "yt": {"protocol": "trojan"},
            "us": {"protocol": "trojan"},
            "userRules": [
                {"domain": "example.com", "action": "direct", "groupTag": ""},
                {"domain": "openai.com", "action": "proxy", "groupTag": ""},
                {"domain": "bilibili.com", "action": "group", "groupTag": "美西"},
                {"domain": "niconico.jp", "action": "group", "groupTag": "影视"},
                {"domain": "orphan.com", "action": "group", "groupTag": "已清空"},
                {"domain": r"regexp:.*\.cdn\d+\.net$", "action": "proxy",
                 "groupTag": ""},
            ],
            "ytGroup": "影视",
            "usGroup": "美西",
        }
        rules = build_user_routing_rules(payload["userRules"],
                                         payload["ytGroup"], payload["usGroup"])
        self.assertEqual([r["outboundTag"] for r in rules],
                         ["direct", "proxy", "proxy", "proxy-yt", "proxy"])
        self.assertEqual(rules[0]["domain"], ["domain:example.com"])
        self.assertEqual(rules[4]["domain"], [r"regexp:.*\.cdn\d+\.net$"])
        # injection into the final chain keeps safety rules ahead
        chain = final_rule_chain("rule", [f"user{i}" for i in range(len(rules))])
        self.assertEqual(chain[3:3 + len(rules)],
                         [f"user{i}" for i in range(len(rules))])

    def test_cap_is_200(self) -> None:
        src = read(RULE_MAP)
        self.assertIn("USER_RULE_MAX_EMIT: number = 200", src)
        many = [{"domain": f"d{i}.com", "action": "proxy", "groupTag": ""}
                for i in range(250)]
        rules = build_user_routing_rules(many, "", "")
        self.assertEqual(len(rules), 200)
        self.assertEqual(rules[-1]["domain"], ["domain:d199.com"])


class UserRuleStoreContract(unittest.TestCase):
    def test_store_source_locks(self) -> None:
        src = read(RULE_STORE)
        self.assertIn("user-rules.json", src)
        self.assertIn("StatusStore.readJsonFile", src)
        self.assertIn("StatusStore.writeJsonAtomic", src)
        self.assertIn("normalizeDomainInput", src)
        # dedupe on normalized domain+action
        self.assertIn("rules[i].domain === check.normalized && rules[i].action === normalizedAction", src)
        self.assertIn("该域名已存在相同动作的规则", src)
        # enabledRoutes feeds SplitRouter and skips disabled rules
        self.assertIn("static enabledRoutes", src)
        self.assertIn("if (!rule.enabled)", src)
        # groupTag only meaningful for group action
        self.assertIn("走节点组需要先选一个分组", src)


class RulesPageContract(unittest.TestCase):
    def test_route_registered_and_index_entry(self) -> None:
        doc = json.loads(read(MAIN_PAGES))
        self.assertIn("pages/Rules", doc["src"])
        src = read(INDEX)
        self.assertIn(".tabBar('规则')", src)
        self.assertIn("Rules({ embedded: true })", src)

    def test_page_sections_and_strings(self) -> None:
        src = read(RULES_PAGE)
        for anchor in (
            "@Entry",
            "连接模式",
            "SettingsStore.update",
            "this.afterRuleChange()",
            "内置模板",
            "国内网站和局域网直连",
            "我的规则",
            "添加规则",
            "直连",
            "走代理",
            "走节点组",
            "暂只支持域名规则",
            "删除这条规则？",
            "需要重新连接才能生效",
            "立即重连",
            "分流规则只在启动连接时读取",
            "UserRuleStore.add",
            "UserRuleStore.remove",
            "UserRuleStore.setEnabled",
            "CONNECTION_CONTROLLER.stop",
            "CONNECTION_CONTROLLER.start",
            # 组映射限制的诚实披露（页脚）
            "选了其他组会在连接时明确报错",
        ):
            self.assertIn(anchor, src, f"Rules page missing {anchor}")


class NodeRunnerWiringContract(unittest.TestCase):
    def test_pure_map_compiled_and_truth_tested(self) -> None:
        self.assertIn("UserRuleMap.ets", read(NODE_RUNNER_BUILD))
        self.assertIn("userrule.test.mjs", read(NODE_RUNNER_PKG))
        test_src = read(NODE_RUNNER_TEST)
        self.assertIn("proxy-yt", test_src)
        self.assertIn("domain:example.com", test_src)


if __name__ == "__main__":
    unittest.main()
