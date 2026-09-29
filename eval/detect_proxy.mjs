#!/usr/bin/env node
// Stand-in benchmark for DialectDetector.swift that runs without a Mac.
// franc (trigrams) stands in for NLLanguageRecognizer and Hunspell (nspell with
// the wooorm dictionaries) for NSSpellChecker; the decision logic is the same.
// Apple's recognizer and dictionaries differ, so on a Mac trust
// DialectDetectorTests.detectionCorpus instead.
//
//   npm i --prefix /tmp/aure-det nspell franc-min dictionary-en dictionary-en-gb dictionary-en-ca
//   NODE_MODULES=/tmp/aure-det/node_modules node eval/detect_proxy.mjs eval/languages/detection.jsonl
//   MODE=threshold ...   # also apply the 0.6 confidence cut to franc's (non-probability) scores
import fs from 'node:fs'
import {createRequire} from 'node:module'
import path from 'node:path'

const base = path.resolve(process.env.NODE_MODULES ?? 'node_modules')
const require = createRequire(base + '/')
const nspell = require('nspell')
const {francAll} = await import(path.join(base, 'franc-min/index.js'))
const load = n => ({aff: fs.readFileSync(path.join(base, n, 'index.aff')), dic: fs.readFileSync(path.join(base, n, 'index.dic'))})
const enUS = load('dictionary-en'), enGB = load('dictionary-en-gb'), enCA = load('dictionary-en-ca')

const spell = {en_US: nspell(enUS), en_GB: nspell(enGB), en_CA: nspell(enCA)}
const ENGLISH = ['en_US', 'en_GB', 'en_CA']
const MIN_LETTERS = 12, MIN_CONF = 0.6
const MODE = process.env.MODE ?? 'top'

const words = t => t.match(/[\p{L}][\p{L}'’]*/gu) ?? []

function language(text) {
  if ((text.match(/\p{L}/gu) ?? []).length < MIN_LETTERS) return null
  const all = francAll(text, {only: ['eng', 'por'], minLength: 1})
  // francAll scores the best as 1; turn the pair into a probability-like share.
  const s = Object.fromEntries(all)
  const e = s.eng ?? 0, p = s.por ?? 0
  const share = Math.max(e, p) / ((e + p) || 1)
  if (MODE === 'threshold' && share < MIN_CONF) return null
  return e >= p ? 'english' : 'portuguese'
}

function rejected(text, d) { return words(text).filter(w => !spell[d].correct(w.replace(/’/g, "'"))).length }

function englishVariant(rej, preferred) {
  const fewest = Math.min(...Object.values(rej))
  const tied = ENGLISH.filter(d => rej[d] === fewest)
  return tied.includes(preferred) ? preferred : tied[0]
}

function detect(text, fallback) {
  const lang = language(text)
  if (!lang) return {dialect: fallback, detected: false}
  if (lang === 'portuguese') return {dialect: 'pt_BR', detected: true}
  const rej = Object.fromEntries(ENGLISH.map(d => [d, rejected(text, d)]))
  const preferred = fallback.startsWith('en') ? fallback : 'en_US'
  return {dialect: englishVariant(rej, preferred), detected: true, rej}
}

const cases = fs.readFileSync(process.argv[2], 'utf8').split('\n').filter(Boolean).map(JSON.parse)
const byGroup = {}, misses = []
const t0 = process.hrtime.bigint()
for (const c of cases) {
  const r = detect(c.text, c.fallback)
  const want = c.expect === 'fallback' ? c.fallback : c.expect
  const ok = r.dialect === want && (c.expect === 'fallback' ? !r.detected : true)
  const g = c.expect === 'fallback' ? 'short → fallback' : (c.note?.startsWith('neutral') ? 'neutral English → preferred' : c.expect)
  byGroup[g] ??= [0, 0]; byGroup[g][1]++; if (ok) byGroup[g][0]++
  else misses.push({text: c.text, want, got: r.dialect, rej: r.rej})
}
const ms = Number(process.hrtime.bigint() - t0) / 1e6
let tot = [0, 0]
for (const [g, [a, n]] of Object.entries(byGroup)) { console.log(`${g.padEnd(30)} ${a}/${n}`); tot[0] += a; tot[1] += n }
console.log(`${'TOTAL'.padEnd(30)} ${tot[0]}/${tot[1]} (${(100 * tot[0] / tot[1]).toFixed(0)}%)   ${(ms / cases.length).toFixed(2)} ms/case`)
for (const m of misses) console.log('MISS', JSON.stringify(m))

