import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import test from 'node:test'

const source = readFileSync(new URL('../plugin.js', import.meta.url), 'utf8')

test('roster highlight follows the clicked bot while its gateway is still waking', () => {
  assert.match(source, /const selectedBot = useValue\(\$selectedBot\)[\s\S]*const isActive = bot\.name === selectedBot/)
})

test('dependent panes prefer the selected bot over a stale live gateway profile', () => {
  assert.match(source, /const bot = \(selected \|\| gatewayProfile \|\| 'default'\)/)
})
