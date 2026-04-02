import Anthropic from '@anthropic-ai/sdk';

function buildPrompt(
  theme: string,
  lyrics: string,
  targetRhymeLine: string | null,
  rhymeType: string,
  rhymeScheme: string,
  currentLetter: string
): string {
  return `You are an expert songwriter and lyricist.
The user is writing a song with the following theme/context: "${theme || 'No specific theme provided'}".
Here are the current lyrics:
"""
${lyrics}
"""

The user needs a line that follows the current lyrics.
The current stanza follows a "${rhymeScheme}" rhyme scheme, and the next line corresponds to the letter "${currentLetter}".
${targetRhymeLine
  ? `Crucially, the new line MUST end with a **${rhymeType}** to this specific line: "${targetRhymeLine}".`
  : `Since this is a new rhyme sound ("${currentLetter}"), the new line should introduce a new end-rhyme that fits the meter and theme.`}

Provide 5 creative, poetic, and contextually relevant suggestions for the next line.
Make sure the rhythm and meter match the style of the current lyrics${targetRhymeLine ? `, and strictly adhere to the requested rhyme type (${rhymeType})` : ''}.

Respond with ONLY a JSON array of 5 strings. Example: ["line 1", "line 2", "line 3", "line 4", "line 5"]`;
}

export async function getRhymeSuggestionsClaude(
  apiKey: string,
  theme: string,
  lyrics: string,
  targetRhymeLine: string | null,
  rhymeType: string,
  rhymeScheme: string,
  currentLetter: string
): Promise<string[]> {
  const client = new Anthropic({ apiKey, dangerouslyAllowBrowser: true });

  const response = await client.messages.create({
    model: 'claude-sonnet-4-20250514',
    max_tokens: 1024,
    messages: [
      { role: 'user', content: buildPrompt(theme, lyrics, targetRhymeLine, rhymeType, rhymeScheme, currentLetter) },
    ],
  });

  try {
    const textBlock = response.content.find((b) => b.type === 'text');
    const text = textBlock && 'text' in textBlock ? textBlock.text.trim() : '[]';
    // Extract JSON array from response (Claude may wrap it in markdown)
    const match = text.match(/\[[\s\S]*\]/);
    if (match) return JSON.parse(match[0]);
    return [];
  } catch (e) {
    console.error('Failed to parse Claude suggestions', e);
    return [];
  }
}
