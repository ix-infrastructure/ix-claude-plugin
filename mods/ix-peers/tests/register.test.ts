import { describe, expect, mock, test } from 'claude-code/testing'
import type { Engine, MockClock } from 'claude-code/testing'
import type { On, RenderElement } from 'claude-code'

import type { Peer, PeerEvent, PeerFrom } from '../types'

const SID = '0d4e2b7c-1111-4222-8333-444455556666'
const SID_AFTER_CLEAR = '9a8b7c6d-1111-4222-8333-444455556666'

const BEN: Peer = {
  sessionId: '6f1c2a90-0000-4000-8000-000000000001',
  ref: 'a1b2c3',
  name: 'ben/api',
  handle: 'ben',
  label: 'api',
  userId: 'u-ben',
  status: 'idle',
  mode: 'default',
  repo: 'Api',
  branch: 'main',
  lastSeenAt: '2026-10-19T12:00:00Z',
}
const ME: Peer = { ...BEN, sessionId: SID, ref: 'ffffff', name: 'sam/web', handle: 'sam', label: 'web', userId: 'u-me', self: true }
/** The same person's session on another machine. */
const MY_LAPTOP: Peer = { ...ME, sessionId: '7b7b7b7b-0000-4000-8000-000000000002', ref: '7b7b7b', name: 'sam/laptop', label: 'laptop', self: undefined }

const fromPeer = (peer: Peer, mode = 'default'): PeerFrom => ({
  sessionId: peer.sessionId,
  ref: peer.ref,
  name: peer.name,
  handle: peer.handle,
  userId: peer.userId,
  mode,
})

const message = (over: Partial<PeerEvent> = {}): PeerEvent =>
  ({
    kind: 'peer.message',
    id: 'ev-1',
    at: '2026-10-19T12:00:01Z',
    toSession: SID,
    from: fromPeer(MY_LAPTOP),
    text: 'Migration landed on main.\nPlease rebase.',
    ...over,
  }) as PeerEvent

type World = {
  runs: { argv: readonly string[]; stdin?: string }[]
  spawns: (readonly string[])[]
  submits: string[]
  notices: string[]
  localSends: string[]
  coreSends: string[]
  emit: (event: PeerEvent) => void
  clock: MockClock
  sessionId: string
}

/**
 * The engine beneath the plugin: an `ix` CLI answering from memory, a watch
 * stream the test feeds, and a SendMessage tool that, like core, raises
 * `session.send` and reports what it answered.
 */
function world(on: On, options: { send?: object; sendExit?: number; env?: Record<string, string> } = {}): World {
  const w: World = { runs: [], spawns: [], submits: [], notices: [], localSends: [], coreSends: [], emit: () => undefined, clock: mock.clock(on), sessionId: SID }
  const queue: string[] = []
  let wake: (() => void) | null = null
  w.emit = event => {
    queue.push(`${JSON.stringify(event)}\n`)
    wake?.()
  }

  mock.env(on, { IX_PEERS_BIN: 'ix', ...options.env })
  on('session.id', () => ({ value: w.sessionId }))
  on('session.cwd', () => ({ value: '/work/web' }))
  on('session.start', (_$, e) => ({ cwd: e.cwd }))
  on('session.end', (_$, e) => ({ sessionId: e.sessionId }))
  on('turn.start', (_$, e) => ({ turnId: e.turnId }))
  on('turn.complete', (_$, e) => ({ text: e.answer }))
  on('classic.SessionStart', () => ({}))
  on('ui.status', () => ({ value: undefined }))
  on('ui.toast', () => ({ value: undefined }))
  on('ui.render', ($, e) => {
    const { Box } = $.ui.resolve(e)

    return h(Box, null) as RenderElement
  })
  on('session.append', (_$, e, next) => {
    if (e.message.type === 'system') w.notices.push(JSON.stringify(e.message.content))

    return next(e)
  })
  on('prompt.submit', (_$, e) => {
    w.submits.push(e.text)

    return { text: e.text }
  })
  on('process.run', (_$, e) => {
    w.runs.push({ argv: e.argv, stdin: e.init?.stdin })
    const [bin, noun, verb] = e.argv
    const ok = (stdout: string, exitCode = 0) => ({ value: { exitCode, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } })
    if (bin === 'git') return ok('', 128)
    if (noun === 'peer' && verb === 'ls') return ok(JSON.stringify({ peers: [{ ...ME, sessionId: w.sessionId }, MY_LAPTOP, BEN] }))
    if (noun === 'peer' && verb === 'send') {
      return ok(JSON.stringify(options.send ?? { delivered: true, to: BEN, messageId: 'm-1' }), options.sendExit ?? 0)
    }

    return ok('{"ok":true}')
  })
  on('process.spawn', async function* (_$, e) {
    w.spawns.push(e.argv)
    for (;;) {
      while (queue.length > 0) yield { stream: 'stdout' as const, text: queue.shift() ?? '' }
      await new Promise<void>(resolve => {
        wake = resolve
      })
    }
  })
  on('session.send', (_$, e) => {
    w.localSends.push(e.to)

    return { isDelivered: false, reason: `No agent or session named ${e.to}.` }
  })
  on('tool.call', { tool: 'ListAgents' }, () => ({ result: { listing: 'researcher [3fa9c1] — idle' } }))
  // Core's SendMessage stands here as a record; the kit cannot raise core's
  // own session.send from it, so tests drive $.session.send directly.
  on('tool.call', { tool: 'SendMessage' }, (_$, e) => {
    w.coreSends.push(String(e.to))

    return { result: `Message sent to ${String(e.to)}.` }
  })
  on('tool.call', { tool: 'Read' }, () => ({ result: { type: 'text', file: { filePath: '/x', content: '', numLines: 0, startLine: 1, totalLines: 0 } } }))

  return w
}

/** Lets the plugin's background loop (the watch) run until `isDone`. */
async function settle(w: World, isDone: () => boolean) {
  for (let i = 0; i < 50 && !isDone(); i++) await w.clock.settle()
}

/** A session started in `mode`, as the classic SessionStart reports it. */
async function start($: Engine, w: World, mode = 'default') {
  await $.session.start({ cwd: '/work/web', surface: 'terminal', isInteractive: true })
  await $.classic.SessionStart({ source: 'startup', permission_mode: mode } as never)
  await settle(w, () => w.runs.some(run => run.argv[2] === 'ls'))
}

describe('ix-peers: sending', () => {
  test('ListAgents gains linked peers with their ix: address, self left out', async ($, on) => {
    const w = world(on)
    await start($, w)
    const ran = await $.tool.call({ tool: 'ListAgents', tool_use_id: 't1' })

    expect(ran.deny).toBeUndefined()
    const listing = (ran.result as { listing: string }).listing
    expect(listing).toContain('researcher [3fa9c1]')
    expect(listing).toContain('ix:ben/api [a1b2c3]')
    expect(listing).toContain('ix:sam/laptop [7b7b7b]')
    expect(listing).not.toContain('sam/web')
  })

  test('SendMessage to an ix: address still runs through core, for its permission check', async ($, on) => {
    const w = world(on)
    await start($, w)
    const ran = await $.tool.call({ tool: 'SendMessage', tool_use_id: 't2', to: 'ix:ben/api', message: 'Rebase onto main please.' })

    expect(w.coreSends).toEqual(['ix:ben/api'])
    expect(ran.isError).toBeUndefined()
  })

  test('session.send to an ix: address is delivered by ix peer send, never locally', async ($, on) => {
    const w = world(on)
    await start($, w)
    const sent = await $.session.send({ to: 'ix:ben/api', text: 'Rebase onto main please.', origin: { kind: 'model' } })

    expect(sent.isDelivered).toBe(true)
    expect(w.localSends).toEqual([])
    const send = w.runs.find(run => run.argv[2] === 'send')
    expect(send?.argv).toEqual(['ix', 'peer', 'send', '--from-session', SID, '--to', 'ben/api', '--json'])
    expect(send?.stdin).toBe('Rebase onto main please.')
  })

  test('session.send to a bare handle stays local, even when a linked peer carries it', async ($, on) => {
    const w = world(on)
    await start($, w)
    const sent = await $.session.send({ to: 'ben', text: 'for the local ben', origin: { kind: 'model' } })

    expect(w.localSends).toEqual(['ben'])
    expect(sent.isDelivered).toBe(false)
    expect(w.runs.some(run => run.argv[2] === 'send')).toBe(false)
  })

  test('an ambiguous address is refused with the candidates to retry', async ($, on) => {
    const w = world(on, {
      sendExit: 1,
      send: { delivered: false, error: 'ambiguous', reason: 'ben has 2 live sessions.', candidates: [BEN, { ...BEN, ref: 'd4e5f6' }] },
    })
    await start($, w)
    const sent = await $.session.send({ to: 'ix:ben', text: 'x', origin: { kind: 'model' } })

    expect(sent.isDelivered).toBe(false)
    expect(sent.reason).toContain('ben has 2 live sessions.')
    expect(sent.reason).toContain('ix:ben/api [d4e5f6]')
  })
})

describe('ix-peers: receiving from your own sessions (the built-in rules)', () => {
  test('a message wakes an idle session, framed as a cross-session message', async ($, on) => {
    const w = world(on)
    await start($, w)
    w.emit(message())
    await settle(w, () => w.submits.length > 0)

    expect(w.submits).toEqual([
      '<cross-session-message from="ix:sam/laptop [7b7b7b]">\nMigration landed on main.\nPlease rebase.\n</cross-session-message>',
    ])
  })

  test('a message for another session is dropped', async ($, on) => {
    const w = world(on)
    await start($, w)
    w.emit(message({ toSession: 'someone-else' }))
    w.emit(message({ id: 'ev-2', text: 'second' }))
    await settle(w, () => w.submits.length > 0)

    expect(w.submits.length).toBe(1)
    expect(w.submits[0]).toContain('second')
  })

  test('while a turn runs, a message drains at the model\'s next tool round', async ($, on) => {
    const w = world(on)
    await start($, w)
    await $.turn.start({ text: 'work', turnId: 'turn-1' } as never)
    w.emit(message())
    await settle(w, () => false)
    const ran = await $.tool.call({ tool: 'Read', tool_use_id: 't6', file_path: '/x' })

    expect(w.submits).toEqual([])
    expect((ran as { context?: readonly string[] }).context?.join('\n')).toContain('from="ix:sam/laptop [7b7b7b]"')
    expect(w.notices.join('\n')).toContain('ix:sam/laptop [7b7b7b] sent a message: Migration landed on main.')
  })

  test('a message queued at the end of a turn starts the next one', async ($, on) => {
    const w = world(on)
    await start($, w)
    await $.turn.start({ text: 'work', turnId: 'turn-1' } as never)
    w.emit(message())
    await settle(w, () => false)
    await $.turn.complete({ turnId: 'turn-1', answer: '', durationMs: 1, isAborted: false, reason: 'answer' } as never)

    expect(w.submits.length).toBe(1)
    expect(w.submits[0]).toContain('Migration landed on main.')
  })

  test('a session in another permission mode is held, then delivered on Deliver', async ($, on) => {
    const w = world(on)
    await start($, w)
    w.emit(message({ from: fromPeer(MY_LAPTOP, 'bypassPermissions') }))
    const ui = await $.ui.mount({ plugin: 'ix-peers', surface: 'terminal', component: 'AbovePrompt', props: {} } as never)
    await settle(w, () => false)

    expect(w.submits).toEqual([])
    await ui.press({ key: 'accept-ev-1' })
    await settle(w, () => w.submits.length > 0)
    expect(w.submits[0]).toContain('Migration landed on main.')
  })

  test('with this session\'s mode unknown, every message is held', async ($, on) => {
    const w = world(on)
    await $.session.start({ cwd: '/work/web', surface: 'terminal', isInteractive: true })
    await settle(w, () => w.runs.some(run => run.argv[2] === 'ls'))
    w.emit(message())
    await settle(w, () => false)

    expect(w.submits).toEqual([])
    expect(w.runs.some(run => run.argv.includes('--mode') && run.argv.includes('unknown'))).toBe(true)
  })

  test('the idle notice notify_when_idle asked for arrives', async ($, on) => {
    const w = world(on)
    await start($, w)
    w.emit({ ...message(), kind: 'peer.idle', reason: 'idle' } as unknown as PeerEvent)
    await settle(w, () => w.submits.length > 0)

    expect(w.submits).toEqual(['[Cross-session idle notice] ix:sam/laptop [7b7b7b] finished what it was doing and is now idle.'])
  })
})

describe('ix-peers: receiving from another person', () => {
  test('is held by default, even when the sender claims this session\'s mode', async ($, on) => {
    const w = world(on)
    await start($, w)
    w.emit(message({ from: fromPeer(BEN, 'default') }))
    await settle(w, () => false)

    expect(w.submits).toEqual([])
  })

  test('is delivered when the person listed the sender in IX_PEERS_AUTO_DELIVER', async ($, on) => {
    const w = world(on, { env: { IX_PEERS_AUTO_DELIVER: 'carol, ben' } })
    await start($, w)
    w.emit(message({ from: fromPeer(BEN, 'default') }))
    await settle(w, () => w.submits.length > 0)

    expect(w.submits[0]).toContain('from="ix:ben/api [a1b2c3]"')
  })

  test('a held message that expires tells its sender, once', async ($, on) => {
    const w = world(on)
    await start($, w)
    w.emit(message({ from: fromPeer(BEN) }))
    await settle(w, () => false)
    await w.clock.advance(10 * 60_000)
    await settle(w, () => false)

    const notices = w.runs.filter(run => run.argv[2] === 'send')
    expect(notices.length).toBe(1)
    expect(notices[0]?.stdin).toContain('expired unread')
    expect(w.submits).toEqual([])
  })
})

describe('ix-peers: lifecycle', () => {
  test('/clear removes the old session\'s presence and registers the new one', async ($, on) => {
    const w = world(on)
    await start($, w)
    await $.session.end({ reason: 'clear', sessionId: SID } as never)
    w.sessionId = SID_AFTER_CLEAR
    await w.clock.advance(1_000)
    await settle(w, () => w.spawns.length > 1)

    expect(w.runs.some(run => run.argv.join(' ') === `ix peer presence ${SID} --remove --json`)).toBe(true)
    expect(w.runs.some(run => run.argv[2] === 'presence' && run.argv[3] === SID_AFTER_CLEAR && !run.argv.includes('--remove'))).toBe(true)
    expect(w.spawns.at(-1)).toEqual(['ix', 'peer', 'watch', '--session', SID_AFTER_CLEAR, '--jsonl'])
  })
})
