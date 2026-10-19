/** A live session as `ix peer ls --json` lists it (the wire contract's Peer). */
export type Peer = {
  sessionId: string
  ref: string
  name: string
  handle: string
  label: string
  userId: string
  status: 'idle' | 'busy'
  mode: string
  repo?: string
  branch?: string
  lastSeenAt: string
  self?: boolean
}

/** Who sent an event, as `ix peer watch` prints it. */
export type PeerFrom = {
  sessionId: string
  ref: string
  name: string
  handle: string
  userId: string
  mode?: string
}

export type IdleReason = 'idle' | 'exited' | 'expired'

/** One line of `ix peer watch --jsonl`. */
export type PeerEvent =
  | { kind: 'peer.message'; id: string; at: string; toSession: string; from: PeerFrom; text: string }
  | { kind: 'peer.idle'; id: string; at: string; toSession: string; from: PeerFrom; reason: IdleReason }

/** A message held for the person's approval: its sender runs in another permission mode. */
export type HeldMessage = {
  id: string
  from: PeerFrom
  text: string
  heldAt: number
}

declare module 'claude-code' {
  interface PluginState {
    'ix-peers': { held: HeldMessage[]; pending: string[] }
  }
}
