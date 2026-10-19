// Copyright 2026 Ix Infrastructure Inc.

// Pure helpers for the ix-peers mod: addressing, framing and parsing of the
// `ix peer` CLI's output. No `$` here, so every rule is unit-testable.

import type { IdleReason, Peer, PeerEvent, PeerFrom } from '../types'

export const IX_PREFIX = 'ix:'

const LABEL_MAX = 40

/** A session label as the contract allows it: `[a-z0-9._-]`, at most 40. */
export function sanitizeLabel(raw: string): string {
  const label = raw
    .toLowerCase()
    .replace(/[^a-z0-9._-]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, LABEL_MAX)

  return label === '' ? 'session' : label
}

/** The `from` address a received message carries: `ix:<name> [<ref>]`. */
export function fromAddress(from: Pick<PeerFrom, 'name' | 'ref'>): string {
  return `${IX_PREFIX}${from.name} [${from.ref}]`
}

/** The address the CLI resolves: the `ix:` prefix dropped, whitespace trimmed. */
export function stripPrefix(to: string): string {
  const trimmed = to.trim()

  return trimmed.startsWith(IX_PREFIX)
    ? trimmed.slice(IX_PREFIX.length).trim()
    : trimmed
}

/**
 * Whether `to` names a live, non-self peer in `peers`: `name [ref]`, `name`,
 * or a bare handle, the same forms the server resolves.
 */
export function matchesPeer(to: string, peers: readonly Peer[]): boolean {
  const address = stripPrefix(to)
  const others = peers.filter(peer => !peer.self)

  return others.some(
    peer =>
      address === `${peer.name} [${peer.ref}]` ||
      address === peer.name ||
      address === peer.handle,
  )
}

/**
 * Whether a SendMessage `to` goes over Ix before local delivery is tried.
 * `ix:` always does; an Ix session name (`handle/label`) does when a peer
 * carries it. A bare handle tries local first: an in-process name wins, as
 * with the built-in.
 */
export function routesToIxFirst(to: string, peers: readonly Peer[]): boolean {
  if (to.trim().startsWith(IX_PREFIX)) {
    return true
  }

  return stripPrefix(to).includes('/') && matchesPeer(to, peers)
}

/**
 * The text the model reads, framed exactly as a local peer's message. Every
 * `&`, `<` and `>` in the body is escaped, so a sender can neither close the
 * frame (in any spelling) nor open a forged one inside it.
 */
export function wrapMessage(from: string, text: string): string {
  const safeFrom = from.replace(/["<>&]/g, '')
  const body = text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')

  return `<cross-session-message from="${safeFrom}">\n${body}\n</cross-session-message>`
}

/** The one-line preview a person sees: the message's first non-empty line. */
export function firstLine(text: string, max = 120): string {
  const line = text.split('\n').find(one => one.trim() !== '')?.trim() ?? ''

  return line.length > max ? `${line.slice(0, max - 1)}…` : line
}

const IDLE_WORDING: Record<IdleReason, string> = {
  idle: 'finished what it was doing and is now idle',
  exited: 'exited',
  expired: 'did not go idle within the subscription\'s lifetime; the idle subscription expired',
}

/** The one-shot notice `notify_when_idle` asked for. */
export function idleNotice(from: PeerFrom, reason: IdleReason): string {
  return `[Cross-session idle notice] ${fromAddress(from)} ${IDLE_WORDING[reason]}.`
}

/** The rows ListAgents gains: one per live peer session, self left out. */
export function peerSection(peers: readonly Peer[]): string {
  const others = peers.filter(peer => !peer.self)
  if (others.length === 0) {
    return ''
  }

  const rows = others.map(peer => {
    const where = [peer.repo, peer.branch].filter(Boolean).join('@')

    return `- ${IX_PREFIX}${peer.name} [${peer.ref}] — ${peer.status}${where ? ` — ${where}` : ''}`
  })

  return [
    '',
    `Ix peers (linked teammates' sessions on other machines, via Ix) — ${others.length}:`,
    ...rows,
    'Address one with SendMessage by its name, e.g. `ix:<name>`; append ` [ref]` only when two rows share a name.',
  ].join('\n')
}

/** Splits streamed stdout into complete lines; the tail is kept for later. */
export function takeLines(buffer: string): { lines: string[]; rest: string } {
  const parts = buffer.split('\n')
  const rest = parts.pop() ?? ''

  return { lines: parts.filter(line => line.trim() !== ''), rest }
}

/** A watch line as an event, or null for anything that is not one. */
export function parseEvent(line: string): PeerEvent | null {
  let value: unknown
  try {
    value = JSON.parse(line)
  } catch {
    return null
  }
  if (typeof value !== 'object' || value === null) {
    return null
  }

  const event = value as Partial<PeerEvent>
  const from = event.from as Partial<PeerFrom> | undefined
  const hasFrom =
    typeof from === 'object' &&
    from !== null &&
    typeof from.name === 'string' &&
    typeof from.ref === 'string'
  if (!hasFrom || typeof event.id !== 'string') {
    return null
  }

  if (event.kind === 'peer.message' && typeof event.text === 'string') {
    return event as PeerEvent
  }
  if (
    event.kind === 'peer.idle' &&
    (event.reason === 'idle' || event.reason === 'exited' || event.reason === 'expired')
  ) {
    return event as PeerEvent
  }

  return null
}

/** The candidates an ambiguous send names, as the model should retry them. */
export function candidateList(candidates: readonly Peer[] | undefined): string {
  if (!candidates || candidates.length === 0) {
    return ''
  }

  return `\nCandidates:\n${candidates.map(peer => `- ${IX_PREFIX}${peer.name} [${peer.ref}] — ${peer.status}`).join('\n')}`
}

/** The JSON object a `--json` command printed, or null. */
export function parseJson<T>(stdout: string): T | null {
  try {
    return JSON.parse(stdout.trim()) as T
  } catch {
    return null
  }
}
