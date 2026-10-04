// 穿山 (GPL-3.0) — 用户分流规则持久化（user-rules.json 的唯一读写方，Phase C2 新增）。
// 向后兼容契约：文件不存在/损坏时 load() 返回空列表，SplitRouter 不带 userRules
// 字段，规则链与 Phase C2 之前逐字节一致。落盘走 StatusStore.readJsonFile /
// writeJsonAtomic（recoverCanonical 自愈 + 原子替换），与 settings.json 同级可靠。
import { common } from '@kit.AbilityKit';
import {
  normalizeDomainInput,
  USER_RULE_ACTION_DIRECT,
  USER_RULE_ACTION_GROUP,
  USER_RULE_ACTION_PROXY,
  UserRuleRoute
} from '../core/UserRuleMap';
import { StatusStore } from './StatusStore';

// user-rules.json v1 顶层结构：
// {"v":1,"rules":[{id,domain,action,groupTag,enabled,createdAt}]}
// domain 存规范化结果（裸域名小写或 regexp: 原样）；action ∈ direct|proxy|group；
// groupTag 仅 action='group' 时有值；enabled=false 的规则不进 payload。
export const USER_RULES_FILE: string = 'user-rules.json';
export const USER_RULES_SCHEMA_VERSION: number = 1;

export class UserRule {
  id: string = '';
  domain: string = '';
  action: string = USER_RULE_ACTION_PROXY;
  groupTag: string = '';
  enabled: boolean = true;
  createdAt: number = 0;
}

export class AddRuleResult {
  ok: boolean = false;
  error: string = '';
}

export class UserRuleStore {
  static load(context: common.Context): Array<UserRule> {
    const raw = StatusStore.readJsonFile(context, USER_RULES_FILE);
    if (raw.length < 2) {
      return [];
    }
    try {
      const parsed = JSON.parse(raw) as Record<string, Object>;
      const arr = parsed['rules'];
      if (arr === undefined || !(arr instanceof Array)) {
        return [];
      }
      const list: Array<UserRule> = [];
      const items = arr as Array<Object>;
      for (let i = 0; i < items.length; i++) {
        const item = items[i];
        if (item === null || typeof item !== 'object') {
          continue;
        }
        const rec = item as Record<string, Object>;
        const rule = new UserRule();
        rule.id = asString(rec['id'], '');
        rule.domain = asString(rec['domain'], '');
        rule.action = normalizeAction(rec['action']);
        rule.groupTag = asString(rec['groupTag'], '');
        rule.enabled = asBool(rec['enabled'], true);
        rule.createdAt = asInt(rec['createdAt'], 0);
        if (rule.domain.length === 0) {
          continue;
        }
        if (rule.id.length === 0) {
          rule.id = makeRuleId(rule.domain, rule.action, rule.createdAt);
        }
        list.push(rule);
      }
      return list;
    } catch (error) {
      console.error(`UserRuleStore.load parse failed ${JSON.stringify(error)}`);
      return [];
    }
  }

  private static save(context: common.Context, rules: Array<UserRule>): void {
    const records: Array<Record<string, Object>> = [];
    for (let i = 0; i < rules.length; i++) {
      const rule = rules[i];
      const rec: Record<string, Object> = {};
      rec['id'] = rule.id;
      rec['domain'] = rule.domain;
      rec['action'] = rule.action;
      rec['groupTag'] = rule.action === USER_RULE_ACTION_GROUP ? rule.groupTag : '';
      rec['enabled'] = rule.enabled;
      rec['createdAt'] = rule.createdAt;
      records.push(rec);
    }
    const doc: Record<string, Object> = {};
    doc['v'] = USER_RULES_SCHEMA_VERSION;
    doc['rules'] = records;
    StatusStore.writeJsonAtomic(context, USER_RULES_FILE, JSON.stringify(doc, null, 2));
  }

  /** SplitRouter prepare 用：只带 enabled 规则的 payload 形状（domain/action/groupTag）。 */
  static enabledRoutes(context: common.Context): Array<UserRuleRoute> {
    const routes: Array<UserRuleRoute> = [];
    const rules = UserRuleStore.load(context);
    for (let i = 0; i < rules.length; i++) {
      const rule = rules[i];
      if (!rule.enabled) {
        continue;
      }
      const route = new UserRuleRoute();
      route.domain = rule.domain;
      route.action = rule.action;
      route.groupTag = rule.action === USER_RULE_ACTION_GROUP ? rule.groupTag : '';
      routes.push(route);
    }
    return routes;
  }

  /**
   * 新增规则：先规范化域名（UserRuleMap），再按 域名+动作 去重。
   * action='group' 时 groupTag 必填且必须是非空字符串（调用方先从 NodeStore 分组选）。
   */
  static add(context: common.Context, domainInput: string, action: string, groupTag: string): AddRuleResult {
    const result = new AddRuleResult();
    const check = normalizeDomainInput(domainInput);
    if (!check.ok) {
      result.error = check.error;
      return result;
    }
    const normalizedAction = normalizeAction(action);
    const tag = normalizedAction === USER_RULE_ACTION_GROUP ? groupTag.trim() : '';
    if (normalizedAction === USER_RULE_ACTION_GROUP && tag.length === 0) {
      result.error = '走节点组需要先选一个分组';
      return result;
    }
    const rules = UserRuleStore.load(context);
    for (let i = 0; i < rules.length; i++) {
      if (rules[i].domain === check.normalized && rules[i].action === normalizedAction) {
        result.error = '该域名已存在相同动作的规则';
        return result;
      }
    }
    const rule = new UserRule();
    rule.domain = check.normalized;
    rule.action = normalizedAction;
    rule.groupTag = tag;
    rule.enabled = true;
    rule.createdAt = Date.now();
    rule.id = makeRuleId(rule.domain, rule.action, rule.createdAt);
    rules.push(rule);
    UserRuleStore.save(context, rules);
    result.ok = true;
    return result;
  }

  static setEnabled(context: common.Context, id: string, enabled: boolean): boolean {
    const rules = UserRuleStore.load(context);
    for (let i = 0; i < rules.length; i++) {
      if (rules[i].id === id) {
        rules[i].enabled = enabled;
        UserRuleStore.save(context, rules);
        return true;
      }
    }
    return false;
  }

  static remove(context: common.Context, id: string): boolean {
    const rules = UserRuleStore.load(context);
    const kept: Array<UserRule> = [];
    let removed = false;
    for (let i = 0; i < rules.length; i++) {
      if (rules[i].id === id) {
        removed = true;
      } else {
        kept.push(rules[i]);
      }
    }
    if (removed) {
      UserRuleStore.save(context, kept);
    }
    return removed;
  }
}

function normalizeAction(value: Object | undefined): string {
  if (value === USER_RULE_ACTION_DIRECT || value === USER_RULE_ACTION_GROUP) {
    return value as string;
  }
  return USER_RULE_ACTION_PROXY;
}

/** 稳定 id：domain|action|createdAt 的 FNV-1a 哈希（与 NodeStore.makeNodeId 同法）。 */
function makeRuleId(domain: string, action: string, createdAt: number): string {
  const value = `${domain}|${action}|${createdAt}`;
  let hash = 2166136261;
  for (let index = 0; index < value.length; index++) {
    hash = (hash ^ value.charCodeAt(index)) * 16777619;
    hash = hash >>> 0;
  }
  return `rule-${hash.toString(16)}`;
}

function asString(value: Object | undefined, fallback: string): string {
  if (typeof value === 'string' && value.length > 0) {
    return value;
  }
  return fallback;
}

function asInt(value: Object | undefined, fallback: number): number {
  if (typeof value === 'number') {
    return value;
  }
  return fallback;
}

function asBool(value: Object | undefined, fallback: boolean): boolean {
  if (typeof value === 'boolean') {
    return value;
  }
  return fallback;
}
