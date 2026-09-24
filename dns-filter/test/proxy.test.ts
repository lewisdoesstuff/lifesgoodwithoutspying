import * as dgram from 'dgram';
import * as net from 'net';
import { describe, expect, it } from 'bun:test';
import { Blocklist } from '../src/blocklist';
import { FilterConfig } from '../src/config';
import { DnsFilterProxy, MAX_TCP_BUFFER } from '../src/proxy';

interface Upstream {
  socket: dgram.Socket;
  port: number;
  queries: Buffer[];
}

interface TcpUpstream {
  server: net.Server;
  port: number;
  queries: Buffer[];
}

function listenUpstream(): Promise<Upstream> {
  return new Promise((resolve, reject) => {
    const socket = dgram.createSocket('udp4');
    const queries: Buffer[] = [];
    socket.on('message', (message, remote) => {
      queries.push(Buffer.from(message));
      const response = Buffer.from(message);
      response.writeUInt16BE(0x8180, 2);
      response.writeUInt16BE(1, 4);
      response.writeUInt16BE(0, 6);
      socket.send(response, remote.port, remote.address);
    });
    socket.once('error', reject);
    socket.bind(0, '127.0.0.1', () => {
      const address = socket.address() as any;
      resolve({ socket, port: address.port, queries });
    });
  });
}

function listenTcpUpstream(): Promise<TcpUpstream> {
  return new Promise((resolve, reject) => {
    const queries: Buffer[] = [];
    const server = net.createServer((socket) => {
      let buffer = Buffer.alloc(0);
      socket.on('data', (chunk) => {
        buffer = Buffer.concat([buffer, chunk]);
        while (buffer.length >= 2) {
          const length = buffer.readUInt16BE(0);
          if (buffer.length < length + 2) {
            return;
          }
          const query = buffer.slice(2, length + 2);
          buffer = buffer.slice(length + 2);
          queries.push(Buffer.from(query));
          const response = Buffer.from(query);
          response.writeUInt16BE(0x8180, 2);
          response.writeUInt16BE(1, 4);
          response.writeUInt16BE(0, 6);
          const frame = Buffer.alloc(response.length + 2);
          frame.writeUInt16BE(response.length, 0);
          response.copy(frame, 2);
          socket.write(frame);
        }
      });
      socket.on('error', () => undefined);
    });
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const address = server.address() as any;
      resolve({ server, port: address.port, queries });
    });
  });
}

function closeServer(server: net.Server): Promise<void> {
  return new Promise((resolve) => {
    try {
      server.close(() => resolve());
    } catch (_error) {
      resolve();
    }
  });
}

function closeSocket(socket: dgram.Socket): Promise<void> {
  return new Promise((resolve) => {
    try {
      socket.close(() => resolve());
    } catch (_error) {
      resolve();
    }
  });
}

function startProxy(proxy: DnsFilterProxy): Promise<void> {
  return new Promise((resolve, reject) => {
    proxy.start((error) => {
      if (error) {
        reject(error);
      } else {
        resolve();
      }
    });
  });
}

function stopProxy(proxy: DnsFilterProxy): Promise<void> {
  return new Promise((resolve) => proxy.close(resolve));
}

function sendQuery(socket: dgram.Socket, port: number, query: Buffer): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      socket.removeListener('message', onMessage);
      reject(new Error('timed out waiting for DNS response'));
    }, 2000);
    const onMessage = (message: Buffer) => {
      clearTimeout(timer);
      resolve(message);
    };
    socket.once('message', onMessage);
    socket.send(query, 0, query.length, port, '127.0.0.1', (error) => {
      if (error) {
        clearTimeout(timer);
        socket.removeListener('message', onMessage);
        reject(error);
      }
    });
  });
}

function makeMaximumTcpFrame(id: number): Buffer {
  const payload = Buffer.alloc(65535);
  payload.writeUInt16BE(id, 0);
  payload.writeUInt16BE(0x0100, 2);
  payload.writeUInt16BE(1, 4);
  let offset = 12;
  for (const label of ['max', 'example', 'test']) {
    payload[offset] = label.length;
    offset += 1;
    payload.write(label, offset, label.length, 'ascii');
    offset += label.length;
  }
  payload[offset] = 0;
  payload.writeUInt16BE(1, offset + 1);
  payload.writeUInt16BE(1, offset + 3);

  const frame = Buffer.alloc(payload.length + 2);
  frame.writeUInt16BE(payload.length, 0);
  payload.copy(frame, 2);
  return frame;
}

function sendTwoMaximumTcpQueries(port: number): Promise<Buffer[]> {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection({ host: '127.0.0.1', port });
    let buffer = Buffer.alloc(0);
    const responses: Buffer[] = [];
    const timer = setTimeout(() => {
      socket.destroy();
      reject(new Error('timed out waiting for maximum TCP responses'));
    }, 5000);

    socket.once('error', (error) => {
      clearTimeout(timer);
      reject(error);
    });
    socket.on('data', (chunk) => {
      buffer = Buffer.concat([buffer, chunk]);
      while (buffer.length >= 2) {
        const length = buffer.readUInt16BE(0);
        if (buffer.length < length + 2) {
          break;
        }
        responses.push(buffer.slice(2, length + 2));
        buffer = buffer.slice(length + 2);
        if (responses.length === 2) {
          clearTimeout(timer);
          socket.destroy();
          resolve(responses);
          return;
        }
      }
    });
    socket.once('connect', () => {
      socket.write(Buffer.concat([
        makeMaximumTcpFrame(0x3001),
        makeMaximumTcpFrame(0x3002),
      ]));
    });
  });
}

function sendTcpQuery(port: number, query: Buffer): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection({ host: '127.0.0.1', port });
    let buffer = Buffer.alloc(0);
    const timer = setTimeout(() => {
      socket.destroy();
      reject(new Error('timed out waiting for TCP DNS response'));
    }, 2000);

    socket.once('error', (error) => {
      clearTimeout(timer);
      reject(error);
    });
    socket.on('data', (chunk) => {
      buffer = Buffer.concat([buffer, chunk]);
      if (buffer.length < 2) {
        return;
      }
      const length = buffer.readUInt16BE(0);
      if (buffer.length < length + 2) {
        return;
      }
      clearTimeout(timer);
      const response = buffer.slice(2, length + 2);
      socket.destroy();
      resolve(response);
    });
    socket.once('connect', () => {
      const frame = Buffer.alloc(query.length + 2);
      frame.writeUInt16BE(query.length, 0);
      query.copy(frame, 2);
      socket.write(frame);
    });
  });
}

function queryFor(name: string, id: number): Buffer {
  const labels = name.split('.');
  let length = 17;
  for (const label of labels) {
    length += label.length + 1;
  }
  const query = Buffer.alloc(length);
  query.writeUInt16BE(id, 0);
  query.writeUInt16BE(0x0100, 2);
  query.writeUInt16BE(1, 4);
  let offset = 12;
  for (const label of labels) {
    query[offset] = label.length;
    offset += 1;
    query.write(label, offset, label.length, 'ascii');
    offset += label.length;
  }
  query[offset] = 0;
  query.writeUInt16BE(1, offset + 1);
  query.writeUInt16BE(1, offset + 3);
  return query;
}

describe('DnsFilterProxy', () => {
  it('allows two maximum-sized TCP frames in the receive buffer', async () => {
    expect(MAX_TCP_BUFFER).toBe((65535 + 2) * 2);

    const upstream = await listenTcpUpstream();
    const config: FilterConfig = {
      listenAddress: '127.0.0.1',
      listenPort: 0,
      upstream: { host: '127.0.0.1', port: upstream.port },
      blocklistPath: 'unused-in-test',
      blocklistFormat: 'domains',
      timeoutMs: 2000,
      logBlocked: false,
    };
    const proxy = new DnsFilterProxy(config, new Blocklist([]));
    try {
      await startProxy(proxy);
      const responses = await sendTwoMaximumTcpQueries(proxy.getListenPort());
      expect(responses).toHaveLength(2);
      expect(responses[0].readUInt16BE(0)).toBe(0x3001);
      expect(responses[1].readUInt16BE(0)).toBe(0x3002);
    } finally {
      await stopProxy(proxy);
      await closeServer(upstream.server);
    }
  }, 10000);

  it('answers blocked UDP queries locally and forwards allowed queries', async () => {
    const upstream = await listenUpstream();
    const config: FilterConfig = {
      listenAddress: '127.0.0.1',
      listenPort: 0,
      upstream: { host: '127.0.0.1', port: upstream.port },
      blocklistPath: 'unused-in-test',
      blocklistFormat: 'domains',
      timeoutMs: 1000,
      logBlocked: false,
    };
    const proxy = new DnsFilterProxy(config, new Blocklist(['blocked.example.test']));
    const client = dgram.createSocket('udp4');

    try {
      await startProxy(proxy);
      const port = proxy.getListenPort();

      const blocked = await sendQuery(client, port, queryFor('blocked.example.test', 0x1001));
      expect(blocked.readUInt16BE(0)).toBe(0x1001);
      expect(blocked.readUInt16BE(2) & 0x8000).toBe(0x8000);
      expect(blocked.readUInt16BE(2) & 0x000f).toBe(3);
      expect(upstream.queries).toHaveLength(0);

      const allowed = await sendQuery(client, port, queryFor('allowed.example.test', 0x1002));
      expect(allowed.readUInt16BE(0)).toBe(0x1002);
      expect(allowed.readUInt16BE(2) & 0x8000).toBe(0x8000);
      expect(upstream.queries).toHaveLength(1);
      expect(upstream.queries[0].readUInt16BE(0)).not.toBe(0x1002);
    } finally {
      await stopProxy(proxy);
      await closeSocket(client);
      await closeSocket(upstream.socket);
    }
  }, 10000);

  it('forwards DNS over TCP using the same listener port as UDP', async () => {
    const upstream = await listenTcpUpstream();
    const config: FilterConfig = {
      listenAddress: '127.0.0.1',
      listenPort: 0,
      upstream: { host: '127.0.0.1', port: upstream.port },
      blocklistPath: 'unused-in-test',
      blocklistFormat: 'domains',
      timeoutMs: 1000,
      logBlocked: false,
    };
    const proxy = new DnsFilterProxy(config, new Blocklist([]));

    try {
      await startProxy(proxy);
      const response = await sendTcpQuery(proxy.getListenPort(), queryFor('tcp.example.test', 0x2001));
      expect(response.readUInt16BE(0)).toBe(0x2001);
      expect(response.readUInt16BE(2) & 0x8000).toBe(0x8000);
      expect(upstream.queries).toHaveLength(1);
    } finally {
      await stopProxy(proxy);
      await closeServer(upstream.server);
    }
  }, 10000);
});
