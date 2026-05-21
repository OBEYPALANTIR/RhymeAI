import { GoogleGenAI } from '@google/genai';

const ai = new GoogleGenAI({ apiKey: process.env.GEMINI_API_KEY });

const SUGGESTION_COUNT = 5;
const MODEL_ID = 'gemini-3.1-pro-preview';

function buildPrompt(
  theme: string,
  lyrics: string,
  targetRhymeLine: string | null,
  rhymeType: string,
  rhymeScheme: string,
  currentLetter: string,
): string {
  const rhymeInstruction = targetRhymeLine
    ? `Crucially, the new line MUST end with a **${rhymeType}** to this specific line: "${targetRhymeLine}".`
    : `Since this is a new rhyme sound ("${currentLetter}"), the new line should introduce a new end-rhyme that fits the meter and theme.`;
  const rhymeAdherence = targetRhymeLine
    ? `, and strictly adhere to the requested rhyme type (${rhymeType})`
    : '';

  return `
You are an expert songwriter and lyricist.
The user is writing a song with the following theme/context: "${theme || 'No specific theme provided'}".
Here are the current lyrics:
"""
${lyrics}
"""

The user needs a line that follows the current lyrics.
The current stanza follows a "${rhymeScheme}" rhyme scheme, and the next line corresponds to the letter "${currentLetter}".
${rhymeInstruction}

Provide ${SUGGESTION_COUNT} creative, poetic, and contextually relevant suggestions for the next line.
Make sure the rhythm and meter match the style of the current lyrics${rhymeAdherence}.

Respond with exactly ${SUGGESTION_COUNT} lines, one suggestion per line. No numbering, no bullets, no quotes, no markdown, no code fences, and no commentary — just the bare suggestion lines.
`;
}

function cleanSuggestionLine(line: string): string | null {
  let cleaned = line.trim();
  if (cleaned.startsWith('```json')) cleaned = cleaned.slice(7);
  if (cleaned.startsWith('```')) cleaned = cleaned.slice(3);
  if (cleaned.endsWith('```')) cleaned = cleaned.slice(0, -3);
  cleaned = cleaned.trim();
  if (!cleaned) return null;
  cleaned = cleaned.replace(/^(?:[-*]\s+|\d+[.)]\s*)/, '');
  if (
    (cleaned.startsWith('"') && cleaned.endsWith('"')) ||
    (cleaned.startsWith("'") && cleaned.endsWith("'"))
  ) {
    if (cleaned.length > 1) cleaned = cleaned.slice(1, -1);
  }
  cleaned = cleaned.trim();
  if (!cleaned || cleaned.length > 140) return null;
  return cleaned;
}

function normalizeKey(text: string): string {
  return text.toLowerCase().replace(/[^a-z0-9]/g, '');
}

export async function* streamRhymeSuggestions(
  theme: string,
  lyrics: string,
  targetRhymeLine: string | null,
  rhymeType: string,
  rhymeScheme: string,
  currentLetter: string,
  signal?: AbortSignal,
): AsyncGenerator<string, void, unknown> {
  const prompt = buildPrompt(theme, lyrics, targetRhymeLine, rhymeType, rhymeScheme, currentLetter);

  const stream = await ai.models.generateContentStream({
    model: MODEL_ID,
    contents: prompt,
  });

  let buffer = '';
  const seen = new Set<string>();
  let emitted = 0;

  const flushLine = (rawLine: string): string | null => {
    const cleaned = cleanSuggestionLine(rawLine);
    if (!cleaned) return null;
    const key = normalizeKey(cleaned);
    if (!key || seen.has(key)) return null;
    seen.add(key);
    return cleaned;
  };

  for await (const chunk of stream) {
    if (signal?.aborted) return;
    if (emitted >= SUGGESTION_COUNT) return;
    const text = chunk.text;
    if (!text) continue;
    buffer += text;

    let newlineIdx = buffer.indexOf('\n');
    while (emitted < SUGGESTION_COUNT && newlineIdx >= 0) {
      const rawLine = buffer.slice(0, newlineIdx);
      buffer = buffer.slice(newlineIdx + 1);
      const result = flushLine(rawLine);
      if (result !== null) {
        yield result;
        emitted++;
      }
      newlineIdx = buffer.indexOf('\n');
    }
  }

  if (emitted < SUGGESTION_COUNT && buffer.trim()) {
    const result = flushLine(buffer);
    if (result !== null) yield result;
  }
}
