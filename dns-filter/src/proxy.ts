import * as dgram from 'dgram';
import * as dns from 'dns';
import * as net from 'net';
import { Blocklist, BlocklistMetadata, loadBlocklist } from './blocklist';
import { FilterConfig } from './config';
import { makeNxDomainResponse, parseDnsQuery } from './dns';

export const MAX_TCP_PAYLOAD = 65535;
export const MAX_TCP_BUFFER = (MAX_TCP_PAYLOAD + 2) * 2;

type LogCallback = (message: string) => void;
type ErrorCallback = (error: Error) => void;

export interface ProxyCallbacks {
  log?: LogCallback;
  error?: ErrorCallback;
}

interface UdpClient {
  address: string;
  port: number;
}

interface PendingUdp {
  client: UdpClient;
  clientId: number;
  timer: any;
}

interface TcpState {
  buffer: Buffer;
  queue: Buffer[];
  busy: boolean;
}

export class DnsFilterProxy {
  private readonly config: FilterConfig;
  private blocklist: Blocklist;
  private readonly callbacks: ProxyCallbacks;
  private readonly pendingUdp = new Map<number, PendingUdp>();
  private readonly tcpClients: net.Socket[] = [];
  private nextUpstreamId = 0;
  private readonly tcpUpstreams: net.Socket[] = [];

  private udp: dgram.Socket | null = null;
  private upstreamUdp: dgram.Socket | null = null;
  private tcp: net.Server | null = null;
  private upstreamAddress = '';
  private upstreamFamily = 4;
  private started = false;
  private closed = false;

  constructor(config: FilterConfig, blocklist: Blocklist, callbacks: ProxyCallbacks = {}) {
    this.config = config;
    this.blocklist = blocklist;
    this.callbacks = callbacks;
  }

  start(callback: (error?: Error) => void): void {
    if (this.started || this.closed) {
      callback(new Error('DNS proxy is already started or closed'));
      return;
    }

    resolveHost(this.config.upstream.host, (error, address, family) => {
      if (error) {
        callback(error);
        return;
      }

      this.upstreamAddress = address || this.config.upstream.host;
      this.upstreamFamily = family || 4;
      this.startSockets(callback);
    });
  }

  getListenPort(): number {
    if (this.udp === null) {
      return this.config.listenPort;
    }
    const address = this.udp.address() as any;
    return address && typeof address === 'object' ? address.port : this.config.listenPort;
  }

  reloadBlocklist(path: string): Blocklist {
    const replacement = loadBlocklist(path, this.config.blocklistFormat);
    this.blocklist = replacement;
    return replacement;
  }

  getBlocklistMetadata(): BlocklistMetadata {
    return this.blocklist.metadata;
  }

  getBlocklistSize(): number {
    return this.blocklist.size;
  }

  close(callback: () => void): void {
    if (this.closed) {
      callback();
      return;
    }
    this.closed = true;

    for (const pending of this.pendingUdp.values()) {
      clearTimeout(pending.timer);
    }
    this.pendingUdp.clear();

    for (const socket of this.tcpClients.slice()) {
      socket.destroy();
    }
    for (const socket of this.tcpUpstreams.slice()) {
      socket.destroy();
    }
    this.tcpClients.length = 0;
    this.tcpUpstreams.length = 0;

    const udp = this.udp;
    const upstreamUdp = this.upstreamUdp;
    const tcp = this.tcp;
    this.udp = null;
    this.upstreamUdp = null;
    this.tcp = null;

    const resources: Array<{ close: (done: () => void) => void }> = [];
    if (udp !== null) {
      resources.push(udp);
    }
    if (upstreamUdp !== null) {
      resources.push(upstreamUdp);
    }
    if (tcp !== null) {
      resources.push(tcp);
    }

    if (resources.length === 0) {
      callback();
      return;
    }

    let completed = 0;
    const done = () => {
      completed += 1;
      if (completed === resources.length) {
        callback();
      }
    };

    for (const resource of resources) {
      try {
        resource.close(done);
      } catch (_error) {
        done();
      }
    }
  }

  private startSockets(callback: (error?: Error) => void): void {
    const listenFamily = net.isIP(this.config.listenAddress);
    const listenType = listenFamily === 6 ? 'udp6' : 'udp4';
    const upstreamType = this.upstreamFamily === 6 ? 'udp6' : 'udp4';
    let startFinished = false;
    const finishStart = (error?: Error) => {
      if (startFinished) {
        if (error) {
          this.reportError(error);
        }
        return;
      }
      startFinished = true;
      callback(error);
    };

    try {
      this.udp = dgram.createSocket(listenType);
      this.upstreamUdp = dgram.createSocket(upstreamType);
    } catch (error) {
      finishStart(asError(error));
      return;
    }

    this.udp.on('message', (message: Buffer, remote: any) => {
      this.handleUdpMessage(message, remote);
    });
    this.upstreamUdp.on('message', (message: Buffer) => this.handleUpstreamUdp(message));
    this.udp.on('error', (error: Error) => {
      if (this.started) {
        this.reportError(error);
      } else {
        finishStart(error);
      }
    });
    this.upstreamUdp.on('error', (error: Error) => {
      if (this.started) {
        this.reportError(error);
      } else {
        finishStart(error);
      }
    });

    this.udp.bind(this.config.listenPort, this.config.listenAddress, (bindError?: Error) => {
      if (bindError) {
        finishStart(bindError);
        return;
      }

      try {
        this.tcp = net.createServer((socket: net.Socket) => this.handleTcpConnection(socket));
        this.tcp.on('error', (error: Error) => {
          if (this.started) {
            this.reportError(error);
          } else {
            finishStart(error);
          }
        });
        this.tcp.listen(this.getListenPort(), this.config.listenAddress, (listenError?: Error) => {
          if (listenError) {
            finishStart(listenError);
            return;
          }
          this.started = true;
          finishStart();
        });
      } catch (error) {
        finishStart(asError(error));
      }
    });
  }

  private handleUdpMessage(message: Buffer, remote: any): void {
    if (this.closed) {
      return;
    }

    const query = parseDnsQuery(message);
    if (query === null) {
      this.log('dropped malformed UDP DNS message');
      return;
    }

    if (this.blocklist.isBlocked(query.name)) {
      const response = makeNxDomainResponse(message, query);
      if (response === null) {
        this.log('dropped blocked multi-question UDP query: ' + query.name);
        return;
      }
      this.logBlocked(query.name);
      this.sendUdp(response, remote.port, remote.address);
      return;
    }

    this.forwardUdp(message, remote);
  }

  private forwardUdp(message: Buffer, remote: any): void {
    const upstreamUdp = this.upstreamUdp;
    if (upstreamUdp === null) {
      return;
    }

    const upstreamId = this.allocateUpstreamId();
    if (upstreamId === null) {
      this.log('dropped UDP query because all upstream IDs are in use');
      return;
    }

    const forwarded = Buffer.from(message);
    forwarded.writeUInt16BE(upstreamId, 0);
    const pending: PendingUdp = {
      client: { address: remote.address, port: remote.port },
      clientId: message.readUInt16BE(0),
      timer: null,
    };
    this.pendingUdp.set(upstreamId, pending);

    pending.timer = setTimeout(() => {
      this.removePendingUdp(upstreamId, pending);
      this.log('upstream UDP timeout for ' + pending.client.address + ':' + pending.client.port);
    }, this.config.timeoutMs);

    try {
      upstreamUdp.send(
        forwarded,
        0,
        forwarded.length,
        this.config.upstream.port,
        this.upstreamAddress,
        (error: Error | null) => {
          if (error) {
            this.removePendingUdp(upstreamId, pending);
            this.log('upstream UDP send failed: ' + error.message);
          }
        },
      );
    } catch (error) {
      this.removePendingUdp(upstreamId, pending);
      this.log('upstream UDP send threw: ' + asError(error).message);
    }
  }

  private handleUpstreamUdp(message: Buffer): void {
    if (message.length < 12 || (message.readUInt16BE(2) & 0x8000) === 0) {
      return;
    }

    const upstreamId = message.readUInt16BE(0);
    const pending = this.pendingUdp.get(upstreamId);
    if (pending === undefined) {
      return;
    }

    this.pendingUdp.delete(upstreamId);
    clearTimeout(pending.timer);
    const response = Buffer.from(message);
    response.writeUInt16BE(pending.clientId, 0);
    const udp = this.udp;
    if (udp !== null) {
      this.sendUdpToClient(udp, response, pending.client);
    }
  }

  private sendUdp(message: Buffer, port: number, address: string): void {
    const udp = this.udp;
    if (udp === null) {
      return;
    }
    this.sendUdpToClient(udp, message, { address, port });
  }

  private sendUdpToClient(udp: dgram.Socket, message: Buffer, client: UdpClient): void {
    try {
      udp.send(message, 0, message.length, client.port, client.address, (error: Error | null) => {
        if (error) {
          this.log('client UDP send failed: ' + error.message);
        }
      });
    } catch (error) {
      this.log('client UDP send threw: ' + asError(error).message);
    }
  }

  private removePendingUdp(id: number, pending: PendingUdp): boolean {
    if (this.pendingUdp.get(id) !== pending) {
      return false;
    }
    clearTimeout(pending.timer);
    this.pendingUdp.delete(id);
    return true;
  }

  private allocateUpstreamId(): number | null {
    for (let attempt = 0; attempt < 0x10000; attempt += 1) {
      const id = this.nextUpstreamId;
      this.nextUpstreamId = (this.nextUpstreamId + 1) & 0xffff;
      if (!this.pendingUdp.has(id)) {
        return id;
      }
    }
    return null;
  }

  private handleTcpConnection(socket: net.Socket): void {
    this.tcpClients.push(socket);
    const state: TcpState = {
      buffer: Buffer.alloc(0),
      queue: [],
      busy: false,
    };

    socket.setTimeout(30000, () => socket.destroy());
    socket.on('data', (chunk: Buffer) => {
      if (socket.destroyed) {
        return;
      }
      state.buffer = Buffer.concat([state.buffer, chunk]);
      if (state.buffer.length > MAX_TCP_BUFFER) {
        this.log('dropped oversized TCP DNS buffer');
        socket.destroy();
        return;
      }
      this.drainTcp(socket, state);
    });
    socket.on('error', (error: Error) => {
      this.log('TCP client error: ' + error.message);
    });
    socket.on('close', () => {
      const index = this.tcpClients.indexOf(socket);
      if (index !== -1) {
        this.tcpClients.splice(index, 1);
      }
    });

    this.drainTcp(socket, state);
  }

  private drainTcp(socket: net.Socket, state: TcpState): void {
    while (!state.busy && state.buffer.length >= 2) {
      const length = socketBufferLength(state.buffer);
      if (length === null) {
        socket.destroy();
        return;
      }
      if (state.buffer.length < length + 2) {
        return;
      }

      const query = state.buffer.slice(2, length + 2);
      state.buffer = state.buffer.slice(length + 2);
      state.queue.push(query);
    }

    if (state.busy || state.queue.length === 0 || socket.destroyed) {
      return;
    }

    const query = state.queue.shift();
    if (query === undefined) {
      return;
    }
    state.busy = true;
    this.handleTcpQuery(query, (response: Buffer | null) => {
      state.busy = false;
      if (response !== null && !socket.destroyed) {
        writeTcpFrame(socket, response, () => {
          this.drainTcp(socket, state);
        });
      } else {
        this.drainTcp(socket, state);
      }
    });
  }

  private handleTcpQuery(query: Buffer, callback: (response: Buffer | null) => void): void {
    const parsed = parseDnsQuery(query);
    if (parsed === null) {
      this.log('dropped malformed TCP DNS message');
      callback(null);
      return;
    }

    if (this.blocklist.isBlocked(parsed.name)) {
      const response = makeNxDomainResponse(query, parsed);
      if (response === null) {
        this.log('dropped blocked multi-question TCP query: ' + parsed.name);
        callback(null);
        return;
      }
      this.logBlocked(parsed.name);
      callback(response);
      return;
    }

    this.forwardTcp(query, callback);
  }

  private forwardTcp(query: Buffer, callback: (response: Buffer | null) => void): void {
    let upstream: net.Socket;
    try {
      upstream = net.createConnection({
        host: this.upstreamAddress,
        port: this.config.upstream.port,
      });
    } catch (error) {
      this.log('upstream TCP connect threw: ' + asError(error).message);
      callback(null);
      return;
    }

    this.tcpUpstreams.push(upstream);
    let responseBuffer = Buffer.alloc(0);
    let finished = false;
    let timer: any = null;

    const finish = (error?: Error, response?: Buffer) => {
      if (finished) {
        return;
      }
      finished = true;
      if (timer !== null) {
        clearTimeout(timer);
      }
      const index = this.tcpUpstreams.indexOf(upstream);
      if (index !== -1) {
        this.tcpUpstreams.splice(index, 1);
      }
      upstream.destroy();
      if (error) {
        this.log('upstream TCP error: ' + error.message);
        callback(null);
      } else {
        callback(response || null);
      }
    };

    timer = setTimeout(() => {
      finish(new Error('upstream TCP timeout'));
    }, this.config.timeoutMs);

    upstream.setTimeout(this.config.timeoutMs, () => {
      finish(new Error('upstream TCP socket timeout'));
    });
    upstream.once('error', (error: Error) => finish(error));
    upstream.once('connect', () => {
      const frame = makeTcpFrame(query);
      try {
        upstream.write(frame);
      } catch (error) {
        finish(asError(error));
      }
    });
    upstream.on('data', (chunk: Buffer) => {
      responseBuffer = Buffer.concat([responseBuffer, chunk]);
      if (responseBuffer.length > MAX_TCP_BUFFER) {
        finish(new Error('oversized upstream TCP DNS response'));
        return;
      }

      const length = socketBufferLength(responseBuffer);
      if (length === null) {
        finish(new Error('invalid upstream TCP DNS length'));
        return;
      }
      if (responseBuffer.length < length + 2) {
        return;
      }
      if (responseBuffer.readUInt16BE(2) !== query.readUInt16BE(0)) {
        finish(new Error('upstream TCP DNS response ID mismatch'));
        return;
      }

      finish(undefined, responseBuffer.slice(2, length + 2));
    });
  }

  private logBlocked(name: string): void {
    if (this.config.logBlocked) {
      this.log('blocked ' + name);
    }
  }

  private log(message: string): void {
    if (this.callbacks.log) {
      this.callbacks.log(message);
    }
  }

  private reportError(error: Error): void {
    if (this.callbacks.error) {
      this.callbacks.error(error);
      return;
    }
    this.log('socket error: ' + error.message);
  }
}

function makeTcpFrame(message: Buffer): Buffer {
  const frame = Buffer.alloc(message.length + 2);
  frame.writeUInt16BE(message.length, 0);
  message.copy(frame, 2);
  return frame;
}

function socketBufferLength(buffer: Buffer): number | null {
  if (buffer.length < 2) {
    return null;
  }
  const length = buffer.readUInt16BE(0);
  return length === 0 ? null : length;
}

function writeTcpFrame(socket: net.Socket, message: Buffer, callback: () => void): void {
  if (socket.destroyed) {
    callback();
    return;
  }
  try {
    socket.write(makeTcpFrame(message), () => callback());
  } catch (_error) {
    callback();
  }
}

function resolveHost(
  host: string,
  callback: (error: Error | null, address?: string, family?: number) => void,
): void {
  const literalFamily = net.isIP(host);
  if (literalFamily !== 0) {
    callback(null, host, literalFamily);
    return;
  }

  dns.lookup(host, (error, address, family) => {
    if (error) {
      callback(error);
      return;
    }
    callback(null, address, family as number);
  });
}

function asError(value: any): Error {
  if (value instanceof Error) {
    return value;
  }
  return new Error(String(value));
}
