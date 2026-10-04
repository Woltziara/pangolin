import { connection, socket } from '@kit.NetworkKit';

// Cumulative milliseconds from call start; -1 means not observed. A SOCKS
// CONNECT reply is not proof that the remote destination has connected.
export class CanaryMarks {
  localTcpDone: number = -1;
  greetingDone: number = -1;
  authDone: number = -1;
  connectReplyDone: number = -1;
  httpSendStart: number = -1;
  httpSendDone: number = -1;
  firstHttpByte: number = -1;
  statusLineDone: number = -1;
  closeStart: number = -1;
  closeDone: number = -1;
  failureStage: string = '';
}

export class CanaryResult {
  ok: boolean = false;
  message: string = '';
  elapsedMs: number = 0;
  httpCode: number = 0;
  marks: CanaryMarks = new CanaryMarks();
}

export async function tcpConnectCanary(host: string, port: number, timeoutMs: number): Promise<CanaryResult> {
  const started = Date.now();
  const result = new CanaryResult();
  if (host.length === 0 || port <= 0) {
    result.message = '节点地址为空';
    return result;
  }
  let tcp: socket.TCPSocket | null = null;
  try {
    const address = host.replace(/^\[|\]$/g, '');
    let candidates: string[] = [address];
    if (!/^\d+\.\d+\.\d+\.\d+$/.test(address) && address.indexOf(':') < 0) {
      const answers = await withTimeout(connection.getAddressesByName(address), timeoutMs, '节点解析超时');
      const ipv4 = answers.filter((a: connection.NetAddress) => /^\d+\.\d+\.\d+\.\d+$/.test(a.address));
      const ipv6 = answers.filter((a: connection.NetAddress) => a.address.indexOf(':') >= 0);
      candidates = [];
      if (ipv4.length > 0) { candidates.push(ipv4[0].address); }
      if (ipv6.length > 0) { candidates.push(ipv6[0].address); }
      if (candidates.length === 0) { throw new Error('节点没有可用地址'); }
    }
    for (let i = 0; i < candidates.length; i++) {
      tcp = socket.constructTCPSocketInstance();
      try {
        const ip = candidates[i];
        await withTimeout(tcp.connect({
          address: { address: ip, port: port, family: ip.indexOf(':') >= 0 ? 2 : 1 },
          timeout: timeoutMs
        }), timeoutMs, '节点 TCP 超时');
        result.ok = true;
        result.message = '节点 TCP 可达';
        break;
      } catch (error) {
        if (i === candidates.length - 1) { throw new Error(errorMessage(error)); }
      } finally {
        await closeTcp(tcp);
        tcp = null;
      }
    }
  } catch (error) {
    result.ok = false;
    result.message = `节点 TCP 失败：${errorMessage(error)}`;
  } finally {
    await closeTcp(tcp);
    result.elapsedMs = Date.now() - started;
  }
  return result;
}

export async function socksHttpCanary(
  socksHost: string,
  socksPort: number,
  destHost: string,
  destPort: number,
  httpHost: string,
  httpPath: string,
  timeoutMs: number,
  socksUser: string,
  socksPass: string
): Promise<CanaryResult> {
  const started = Date.now();
  const result = new CanaryResult();
  let tcp: socket.TCPSocket | null = null;
  const inbox: Array<Uint8Array> = [];
  let notify: (() => void) | null = null;
  let stage = 'local-tcp';

  try {
    tcp = socket.constructTCPSocketInstance();
    tcp.on('message', (value: socket.SocketMessageInfo) => {
      if (stage === 'http' && value.message.byteLength > 0 && result.marks.firstHttpByte < 0) {
        result.marks.firstHttpByte = Date.now() - started;
      }
      inbox.push(new Uint8Array(value.message));
      if (notify !== null) {
        notify();
      }
    });
    await withTimeout(
      tcp.connect({
        address: { address: socksHost, port: socksPort, family: 1 },
        timeout: timeoutMs
      }),
      timeoutMs,
      'SOCKS 连接超时'
    );
    result.marks.localTcpDone = Date.now() - started;
    stage = 'socks-greeting';

    const useAuth = socksUser.length > 0 && socksPass.length > 0;
    const handshake = new Uint8Array(useAuth ? 4 : 3);
    handshake[0] = 0x05;
    if (useAuth) {
      handshake[1] = 0x02;
      handshake[2] = 0x00;
      handshake[3] = 0x02;
    } else {
      handshake[1] = 0x01;
      handshake[2] = 0x00;
    }
    await tcp.send({ data: copyBuffer(handshake) });
    const helloReply = await readExact(inbox, () => {
      notify = null;
    }, (fn: () => void) => {
      notify = fn;
    }, 2, timeoutMs);
    if (helloReply[0] !== 0x05) {
      throw new Error(`SOCKS 握手失败 ${helloReply[0]},${helloReply[1]}`);
    }
    result.marks.greetingDone = Date.now() - started;
    stage = 'socks-auth';
    if (useAuth) {
      if (helloReply[1] !== 0x02) {
        throw new Error(`SOCKS 未接受用户名认证 ${helloReply[1]}`);
      }
      const userBytes = stringToBytes(socksUser);
      const passBytes = stringToBytes(socksPass);
      const auth = new Uint8Array(3 + userBytes.length + passBytes.length);
      auth[0] = 0x01;
      auth[1] = userBytes.length;
      for (let i = 0; i < userBytes.length; i++) {
        auth[2 + i] = userBytes[i];
      }
      auth[2 + userBytes.length] = passBytes.length;
      for (let j = 0; j < passBytes.length; j++) {
        auth[3 + userBytes.length + j] = passBytes[j];
      }
      await tcp.send({ data: copyBuffer(auth) });
      const authReply = await readExact(inbox, () => {
        notify = null;
      }, (fn: () => void) => {
        notify = fn;
      }, 2, timeoutMs);
      if (authReply[1] !== 0x00) {
        throw new Error('SOCKS 用户名认证失败');
      }
    } else if (helloReply[1] !== 0x00) {
      throw new Error(`SOCKS 握手失败 ${helloReply[0]},${helloReply[1]}`);
    }
    result.marks.authDone = Date.now() - started;
    stage = 'socks-connect-reply';

    const request = buildConnectRequest(destHost, destPort);
    await tcp.send({ data: copyBuffer(request) });
    const reply = await readExact(inbox, () => {
      notify = null;
    }, (fn: () => void) => {
      notify = fn;
    }, 10, timeoutMs);
    if (reply[0] !== 0x05 || reply[1] !== 0x00) {
      throw new Error(`SOCKS CONNECT 失败 code=${reply[1]}`);
    }
    result.marks.connectReplyDone = Date.now() - started;

    const http = `GET ${httpPath} HTTP/1.1\r\nHost: ${httpHost}\r\nConnection: close\r\n\r\n`;
    stage = 'http';
    result.marks.httpSendStart = Date.now() - started;
    await tcp.send({ data: http });
    result.marks.httpSendDone = Date.now() - started;
    const body = await readUntil(inbox, () => {
      notify = null;
    }, (fn: () => void) => {
      notify = fn;
    }, timeoutMs);
    const text = bytesToAscii(body);
    const first = text.split('\r\n')[0];
    result.marks.statusLineDone = Date.now() - started;
    const code = Number.parseInt(first.split(' ')[1], 10);
    result.httpCode = Number.isNaN(code) ? 0 : code;
    if (text.indexOf('HTTP/1.1 204') >= 0 || text.indexOf('HTTP/1.0 204') >= 0 ||
      text.indexOf('HTTP/1.1 200') >= 0 || text.indexOf('HTTP/1.0 200') >= 0 ||
      text.indexOf('HTTP/1.1 301') >= 0 || text.indexOf('HTTP/1.1 302') >= 0) {
      result.ok = true;
      result.message = `SOCKS HTTP 成功 ${first}`;
    } else {
      result.ok = false;
      result.message = `SOCKS HTTP 异常 ${first}`;
    }
  } catch (error) {
    result.ok = false;
    result.message = `SOCKS 探测失败：${errorMessage(error)}`;
    result.marks.failureStage = stage;
  } finally {
    result.marks.closeStart = Date.now() - started;
    await closeTcp(tcp);
    result.marks.closeDone = Date.now() - started;
    result.elapsedMs = Date.now() - started;
  }
  return result;
}

function buildConnectRequest(host: string, port: number): Uint8Array {
  const hostBytes = stringToBytes(host);
  const out = new Uint8Array(7 + hostBytes.length);
  out[0] = 0x05;
  out[1] = 0x01;
  out[2] = 0x00;
  out[3] = 0x03;
  out[4] = hostBytes.length;
  for (let i = 0; i < hostBytes.length; i++) {
    out[5 + i] = hostBytes[i];
  }
  out[5 + hostBytes.length] = (port >> 8) & 0xff;
  out[6 + hostBytes.length] = port & 0xff;
  return out;
}

function copyBuffer(bytes: Uint8Array): ArrayBuffer {
  const out = new ArrayBuffer(bytes.length);
  const view = new Uint8Array(out);
  view.set(bytes);
  return out;
}

function stringToBytes(value: string): Uint8Array {
  const bytes = new Uint8Array(value.length);
  for (let i = 0; i < value.length; i++) {
    bytes[i] = value.charCodeAt(i) & 0xff;
  }
  return bytes;
}

function bytesToAscii(bytes: Uint8Array): string {
  let text = '';
  const limit = bytes.length < 256 ? bytes.length : 256;
  for (let i = 0; i < limit; i++) {
    text += String.fromCharCode(bytes[i]);
  }
  return text;
}

async function readExact(
  inbox: Array<Uint8Array>,
  clearNotify: () => void,
  setNotify: (fn: () => void) => void,
  count: number,
  timeoutMs: number
): Promise<Uint8Array> {
  const started = Date.now();
  let acc = new Uint8Array(0);
  while (acc.length < count) {
    acc = concatInbox(inbox, acc);
    if (acc.length >= count) {
      const extra = acc.slice(count);
      inbox.length = 0;
      if (extra.length > 0) {
        inbox.push(extra);
      }
      return acc.slice(0, count);
    }
    const remain = timeoutMs - (Date.now() - started);
    if (remain <= 0) {
      throw new Error('SOCKS 读超时');
    }
    await waitNotify(setNotify, clearNotify, remain);
  }
  return acc;
}

async function readUntil(
  inbox: Array<Uint8Array>,
  clearNotify: () => void,
  setNotify: (fn: () => void) => void,
  timeoutMs: number
): Promise<Uint8Array> {
  const started = Date.now();
  let acc = new Uint8Array(0);
  while (Date.now() - started < timeoutMs) {
    acc = concatInbox(inbox, acc);
    const text = bytesToAscii(acc);
    if (text.indexOf('\r\n') >= 0) {
      return acc;
    }
    const remain = timeoutMs - (Date.now() - started);
    if (remain <= 0) {
      break;
    }
    try {
      await waitNotify(setNotify, clearNotify, remain);
    } catch (error) {
      break;
    }
  }
  if (acc.length === 0) {
    throw new Error('SOCKS HTTP 无响应');
  }
  return acc;
}

function concatInbox(inbox: Array<Uint8Array>, acc: Uint8Array): Uint8Array {
  if (inbox.length === 0) {
    return acc;
  }
  let extra = 0;
  for (let i = 0; i < inbox.length; i++) {
    extra += inbox[i].length;
  }
  const next = new Uint8Array(acc.length + extra);
  next.set(acc, 0);
  let offset = acc.length;
  for (let i = 0; i < inbox.length; i++) {
    next.set(inbox[i], offset);
    offset += inbox[i].length;
  }
  inbox.length = 0;
  return next;
}

function waitNotify(setNotify: (fn: () => void) => void, clearNotify: () => void, timeoutMs: number): Promise<void> {
  return new Promise<void>((resolve: () => void, reject: (reason: Error) => void) => {
    const timer = setTimeout(() => {
      clearNotify();
      reject(new Error('SOCKS 读超时'));
    }, timeoutMs);
    setNotify(() => {
      clearTimeout(timer);
      clearNotify();
      resolve();
    });
  });
}

async function withTimeout<T>(work: Promise<T>, timeoutMs: number, message: string): Promise<T> {
  let timer = -1;
  const timeout = new Promise<T>((_resolve: (value: T) => void, reject: (reason: Error) => void) => {
    timer = setTimeout(() => {
      reject(new Error(message));
    }, timeoutMs);
  });
  try {
    return await Promise.race([work, timeout]);
  } finally {
    if (timer >= 0) {
      clearTimeout(timer);
    }
  }
}

async function closeTcp(tcp: socket.TCPSocket | null): Promise<void> {
  if (tcp === null) {
    return;
  }
  try {
    tcp.off('message');
    await tcp.close();
  } catch (error) {
    // ignore
  }
}

function errorMessage(error: Object): string {
  const record = error as Record<string, Object>;
  const message = record['message'];
  if (typeof message === 'string' && message.length > 0) {
    return message;
  }
  return JSON.stringify(error);
}
