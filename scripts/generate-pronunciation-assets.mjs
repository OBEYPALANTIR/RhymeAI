import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const SOURCE_URL =
  'https://raw.githubusercontent.com/words/cmu-pronouncing-dictionary/master/index.js';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const SHARED_OUT = resolve(ROOT, 'shared/pronunciation/cmudict-rhymeai.tsv');
const IOS_OUT = resolve(ROOT, 'Writers Block/Writers Block/Resources/cmudict-rhymeai.tsv');

function stripVariant(word) {
  return word.replace(/\(\d+\)$/, '');
}

function parseDictionary(source) {
  const grouped = new Map();
  const entryPattern = /^\s*"([^"]+)":\s*"([^"]+)",?\s*$/;

  for (const line of source.split('\n')) {
    const match = line.match(entryPattern);
    if (!match) continue;

    const word = stripVariant(match[1].toLowerCase());
    const phones = match[2].trim().replace(/\s+/g, ' ');
    if (!word || !phones) continue;

    const variants = grouped.get(word) ?? [];
    if (!variants.includes(phones)) {
      variants.push(phones);
      grouped.set(word, variants);
    }
  }

  return grouped;
}

function serialize(grouped) {
  const lines = [
    '# RhymeAI CMU pronunciation data',
    `# Source: ${SOURCE_URL}`,
    '# Format: word<TAB>ARPABET variant|ARPABET variant',
  ];

  for (const word of [...grouped.keys()].sort()) {
    lines.push(`${word}\t${grouped.get(word).join('|')}`);
  }

  return `${lines.join('\n')}\n`;
}

const response = await fetch(SOURCE_URL);
if (!response.ok) {
  throw new Error(`Failed to fetch CMU dictionary: ${response.status} ${response.statusText}`);
}

const source = await response.text();
const output = serialize(parseDictionary(source));

for (const target of [SHARED_OUT, IOS_OUT]) {
  mkdirSync(dirname(target), { recursive: true });
  writeFileSync(target, output, 'utf8');
}

console.log(`Wrote ${output.split('\n').length - 1} pronunciation rows to:`);
console.log(`- ${SHARED_OUT}`);
console.log(`- ${IOS_OUT}`);
