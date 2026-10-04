// 穿山 (GPL-3.0) — 节点地区推断。
// 纯函数模块：不依赖 @kit/@ohos，可在 Node 单元测试（tsc）下编译运行。

export const REGION_OTHER: string = '其他';

interface RegionKeywordRule {
  region: string;
  keywords: Array<string>;
}

// 命中即返回，靠前的规则优先。匹配对大小写不敏感。
const REGION_RULES: Array<RegionKeywordRule> = [
  { region: '中国香港', keywords: ['香港', 'hong kong', 'hongkong', 'hk'] },
  { region: '中国台湾', keywords: ['台湾', 'taiwan', 'tw'] },
  { region: '美国', keywords: ['美国', 'united states', 'america', 'us'] },
  { region: '日本', keywords: ['日本', 'japan', 'jp'] },
  { region: '新加坡', keywords: ['新加坡', 'singapore', 'sg'] },
  { region: '韩国', keywords: ['韩国', 'korea', 'kr'] },
  { region: '英国', keywords: ['英国', 'united kingdom', 'britain', 'uk'] },
  { region: '德国', keywords: ['德国', 'germany', 'deutschland', 'de'] }
];

function containsKeyword(text: string, keyword: string): boolean {
  if (keyword.length <= 2 && isAsciiWord(keyword)) {
    // 短英文缩写（hk/us/jp/sg/tw/kr/uk/de）按词边界匹配，避免 "uk" 命中 "ukraine" 之类。
    return matchAsciiWord(text, keyword);
  }
  return text.indexOf(keyword) >= 0;
}

function isAsciiWord(value: string): boolean {
  for (let i = 0; i < value.length; i++) {
    const code = value.charCodeAt(i);
    if (code < 97 || code > 122) {
      return false;
    }
  }
  return value.length > 0;
}

function matchAsciiWord(text: string, word: string): boolean {
  let from = 0;
  while (from <= text.length - word.length) {
    const hit = text.indexOf(word, from);
    if (hit < 0) {
      return false;
    }
    const before = hit > 0 ? text.charCodeAt(hit - 1) : 0;
    const afterIndex = hit + word.length;
    const after = afterIndex < text.length ? text.charCodeAt(afterIndex) : 0;
    if (!isAsciiLetter(before) && !isAsciiLetter(after)) {
      return true;
    }
    from = hit + 1;
  }
  return false;
}

function isAsciiLetter(code: number): boolean {
  return (code >= 97 && code <= 122) || (code >= 65 && code <= 90);
}

/**
 * 根据节点名称（首选）与服务器地址推断地区标签。
 * 命中不了时返回 REGION_OTHER（“其他”）。
 */
export function guessRegion(name: string, server: string): string {
  const haystack = `${name} ${server}`.toLowerCase();
  for (let i = 0; i < REGION_RULES.length; i++) {
    const rule = REGION_RULES[i];
    for (let j = 0; j < rule.keywords.length; j++) {
      if (containsKeyword(haystack, rule.keywords[j])) {
        return rule.region;
      }
    }
  }
  return REGION_OTHER;
}
