// 穿山 (GPL-3.0) — Phase C2 用户分流规则的纯函数部分：域名规范化、Xray 域名语法、
// 节点组 → 分流线路映射。本文件不 import 任何 @kit/@ohos 模块，node-runner
// （tests/node-runner）可直接用 tsc 编译并跑真值测试（userrule.test.mjs）。
// 使用方：services/UserRuleStore.ets（增删校验）、core/XrayRuntime.ets（规则注入）。

export const USER_RULE_ACTION_DIRECT: string = 'direct';
export const USER_RULE_ACTION_PROXY: string = 'proxy';
export const USER_RULE_ACTION_GROUP: string = 'group';
// 注入规则数上限：超出截断（用户规则再多也不拖垮路由匹配）。
export const USER_RULE_MAX_EMIT: number = 200;

export class DomainCheck {
  ok: boolean = false;
  // 规范化结果：裸域名小写（example.com），或原样保留的 regexp: 表达式。
  normalized: string = '';
  error: string = '';
}

// SplitRouter payload userRules 数组里单条的形状（只带 enabled 规则）。
export class UserRuleRoute {
  domain: string = '';
  action: string = '';
  groupTag: string = '';
}

const REGEXP_PREFIX: string = 'regexp:';
const IP_LIKE: RegExp = /^[0-9.:]+$/;
const LABEL: RegExp = /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/;
const TLD: RegExp = /^[a-z]{2,}$/;

function fail(error: string): DomainCheck {
  const result = new DomainCheck();
  result.ok = false;
  result.error = error;
  return result;
}

/**
 * 规范化用户输入的域名规则：
 * - 'example.com' / 'EXAMPLE.com' / '*.example.com' → 'example.com'
 *   （Xray domain: 语义，匹配域名本身与所有子域名）；
 * - 'regexp:...' 高级写法原样透传（前缀后内容可空则拒绝）；
 * - IP / CIDR（1.2.3.4、10.0.0.0/8、::1）拒绝：暂只支持域名规则；
 * - 其余畸形输入拒绝并给出中文提示。
 */
export function normalizeDomainInput(raw: string): DomainCheck {
  const input = raw.trim();
  if (input.length === 0) {
    return fail('请输入域名');
  }
  if (input.length > 253) {
    return fail('域名过长');
  }
  if (input.indexOf(REGEXP_PREFIX) === 0) {
    const expr = input.substring(REGEXP_PREFIX.length).trim();
    if (expr.length === 0) {
      return fail('regexp: 后面需要跟上正则表达式');
    }
    const result = new DomainCheck();
    result.ok = true;
    result.normalized = `${REGEXP_PREFIX}${expr}`;
    return result;
  }
  if (input.indexOf('/') >= 0 || IP_LIKE.test(input)) {
    return fail('暂只支持域名规则');
  }
  if (input.indexOf(':') >= 0) {
    return fail('只支持 regexp: 前缀的高级写法');
  }
  let bare = input;
  if (bare.indexOf('*.') === 0) {
    bare = bare.substring(2);
  }
  bare = bare.toLowerCase();
  if (bare.indexOf('.') < 0) {
    return fail('请输入完整域名（如 example.com）');
  }
  const labels = bare.split('.');
  for (let i = 0; i < labels.length; i++) {
    if (!LABEL.test(labels[i])) {
      return fail('域名格式不正确');
    }
  }
  if (!TLD.test(labels[labels.length - 1])) {
    return fail('域名格式不正确');
  }
  const result = new DomainCheck();
  result.ok = true;
  result.normalized = bare;
  return result;
}

/** 规范化域名 → Xray 路由域名语法：裸域名加 domain: 前缀，regexp: 原样透传。 */
export function xrayDomainOf(normalized: string): string {
  if (normalized.indexOf(REGEXP_PREFIX) === 0) {
    return normalized;
  }
  return `domain:${normalized}`;
}

/**
 * 用户规则 → Xray field 规则数组（每条用户规则一条 field rule，便于排查）。
 * action: direct → 'direct'；proxy → 'proxy'；group → 节点组映射到两条分流线路：
 * groupTag 命中美国腿（usGroup）→ 'proxy'，命中 YouTube 腿（ytGroup）→ 'proxy-yt'。
 * 两腿都不命中时不静默改走默认代理：该条不生成，由 unmappedGroupRuleError 在启动时报错。
 * 超过 USER_RULE_MAX_EMIT 条时截断。
 */
export function buildUserRoutingRules(routes: UserRuleRoute[], ytGroup: string,
  usGroup: string, defaultProxyTag: string = 'proxy'): Array<Record<string, Object>> {
  const rules: Array<Record<string, Object>> = [];
  for (let i = 0; i < routes.length && rules.length < USER_RULE_MAX_EMIT; i++) {
    const route = routes[i];
    if (route.domain.length === 0) {
      continue;
    }
    let tag = '';
    if (route.action === USER_RULE_ACTION_DIRECT) {
      tag = 'direct';
    } else if (route.action === USER_RULE_ACTION_PROXY) {
      tag = defaultProxyTag;
    } else if (route.action === USER_RULE_ACTION_GROUP) {
      tag = groupLegTag(route.groupTag, ytGroup, usGroup);
      if (tag.length === 0) {
        continue;
      }
    } else {
      continue;
    }
    const rule: Record<string, Object> = {};
    rule['type'] = 'field';
    rule['domain'] = [xrayDomainOf(route.domain)];
    rule['outboundTag'] = tag;
    rules.push(rule);
  }
  return rules;
}

export function unmappedGroupRuleError(routes: UserRuleRoute[], ytGroup: string, usGroup: string): string {
  for (let i = 0; i < routes.length; i++) {
    const route = routes[i];
    if (route.action !== USER_RULE_ACTION_GROUP) {
      continue;
    }
    if (groupLegTag(route.groupTag, ytGroup, usGroup).length === 0) {
      const group = route.groupTag.length > 0 ? route.groupTag : '(空)';
      return `规则 ${route.domain} 指定的分组「${group}」当前没有对应线路`;
    }
  }
  return '';
}

function groupLegTag(groupTag: string, ytGroup: string, usGroup: string): string {
  if (groupTag.length > 0 && groupTag === usGroup) {
    return 'proxy';
  }
  if (groupTag.length > 0 && groupTag === ytGroup) {
    return 'proxy-yt';
  }
  return '';
}
