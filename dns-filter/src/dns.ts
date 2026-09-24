export interface DnsQuestion {
  name: string;
  end: number;
}

export interface DnsQuery {
  id: number;
  flags: number;
  name: string;
  questionEnd: number;
  questionCount: number;
}

const MAX_DNS_NAME_LENGTH = 255;
const MAX_LABEL_LENGTH = 63;
const MAX_COMPRESSION_JUMPS = 32;

/**
 * Normalize a DNS name for blocklist comparisons. DNS names are treated as
 * ASCII (normally punycode) so that the same normalization works on old Node
 * runtimes without depending on Unicode or IDN APIs.
 */
export function normalizeDomain(value: string): string {
  let domain = value.trim().toLowerCase();

  while (domain.length > 0 && domain.charAt(domain.length - 1) === '.') {
    domain = domain.slice(0, -1);
  }

  if (domain.length === 0 || domain.length > MAX_DNS_NAME_LENGTH - 1) {
    return '';
  }

  const labels = domain.split('.');
  for (const label of labels) {
    if (
      label.length === 0 ||
      label.length > MAX_LABEL_LENGTH ||
      !/^[a-z0-9_](?:[a-z0-9_-]*[a-z0-9_])?$/.test(label)
    ) {
      return '';
    }
  }

  return domain;
}

function isSafeLabel(label: string): boolean {
  return (
    label.length > 0 &&
    label.length <= MAX_LABEL_LENGTH &&
    /^[a-z0-9_](?:[a-z0-9_-]*[a-z0-9_])?$/.test(label)
  );
}

/**
 * Read a possibly compressed DNS name. `end` points immediately after the
 * encoded name in the original message, which is what callers need when they
 * copy a question into a synthesized response.
 */
export function readDnsName(message: Buffer, offset: number): DnsQuestion | null {
  let cursor = offset;
  let encodedEnd = -1;
  let jumps = 0;
  let nameLength = 0;
  const labels: string[] = [];
  const visited: boolean[] = [];

  while (true) {
    if (cursor < 0 || cursor >= message.length) {
      return null;
    }

    const length = message[cursor];

    if ((length & 0xc0) === 0xc0) {
      if (cursor + 1 >= message.length) {
        return null;
      }

      if (encodedEnd < 0) {
        encodedEnd = cursor + 2;
      }

      const pointer = ((length & 0x3f) << 8) | message[cursor + 1];
      if (pointer >= cursor || pointer >= message.length || visited[pointer]) {
        return null;
      }

      jumps += 1;
      if (jumps > MAX_COMPRESSION_JUMPS) {
        return null;
      }

      visited[pointer] = true;
      cursor = pointer;
      continue;
    }

    if ((length & 0xc0) !== 0) {
      return null;
    }

    cursor += 1;
    if (length === 0) {
      if (encodedEnd < 0) {
        encodedEnd = cursor;
      }
      break;
    }

    if (length > MAX_LABEL_LENGTH || cursor + length > message.length) {
      return null;
    }

    nameLength += length + 1;
    if (nameLength > MAX_DNS_NAME_LENGTH - 1) {
      return null;
    }

    const label = message.toString('ascii', cursor, cursor + length).toLowerCase();
    if (!isSafeLabel(label)) {
      return null;
    }

    labels.push(label);
    cursor += length;
  }

  if (labels.length === 0) {
    return null;
  }

  return {
    name: labels.join('.'),
    end: encodedEnd,
  };
}

/**
 * Parse the first question in a conventional, uncompressed-or-compressed DNS
 * query. Queries with a non-zero QR bit, non-standard opcode, or a truncated
 * question are rejected. Multiple-question messages are retained so callers
 * can forward them, but cannot be answered by the simple NXDOMAIN synthesizer.
 */
export function parseDnsQuery(message: Buffer): DnsQuery | null {
  if (message.length < 12) {
    return null;
  }

  const flags = message.readUInt16BE(2);
  if ((flags & 0x8000) !== 0 || ((flags >> 11) & 0x0f) !== 0) {
    return null;
  }

  const questionCount = message.readUInt16BE(4);
  if (questionCount < 1) {
    return null;
  }

  const question = readDnsName(message, 12);
  if (question === null || question.end + 4 > message.length) {
    return null;
  }

  return {
    id: message.readUInt16BE(0),
    flags,
    name: question.name,
    questionEnd: question.end + 4,
    questionCount,
  };
}

/**
 * Build a minimal NXDOMAIN response containing the original question. This
 * deliberately drops EDNS and additional sections rather than copying
 * attacker-controlled records into a response generated locally.
 */
export function makeNxDomainResponse(query: Buffer, parsed: DnsQuery): Buffer | null {
  if (parsed.questionCount !== 1 || parsed.questionEnd > query.length) {
    return null;
  }

  const questionLength = parsed.questionEnd - 12;
  const response = Buffer.alloc(12 + questionLength);
  query.copy(response, 0, 0, 2);

  // QR + the client's RD bit + NXDOMAIN. Other response bits are controlled by
  // this helper and are intentionally not echoed from the query.
  response.writeUInt16BE(0x8000 | (parsed.flags & 0x0100) | 0x0003, 2);
  response.writeUInt16BE(1, 4);
  response.writeUInt16BE(0, 6);
  response.writeUInt16BE(0, 8);
  response.writeUInt16BE(0, 10);
  query.copy(response, 12, 12, parsed.questionEnd);

  return response;
}
