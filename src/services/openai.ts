import OpenAI from 'openai';

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

Respond with a JSON array of 5 strings. Example: ["line 1", "line 2", "line 3", "line 4", "line 5"]`;
}

export async function getRhymeSuggestionsOpenAI(
  apiKey: string,
  theme: string,
  lyrics: string,
  targetRhymeLine: string | null,
  rhymeType: string,
  rhymeScheme: string,
  currentLetter: string
): Promise<string[]> {
  const client = new OpenAI({ apiKey, dangerouslyAllowBrowser: true });

  const response = await client.chat.completions.create({
    model: 'gpt-4o',
    messages: [
      { role: 'user', content: buildPrompt(theme, lyrics, targetRhymeLine, rhymeType, rhymeScheme, currentLetter) },
    ],
    response_format: { type: 'json_object' },
  });

  try {
    const text = response.choices[0]?.message?.content?.trim() || '{}';
    const parsed = JSON.parse(text);
    // Handle both { suggestions: [...] } and direct array formats
    if (Array.isArray(parsed)) return parsed;
    const values = Object.values(parsed);
    if (values.length > 0 && Array.isArray(values[0])) return values[0] as string[];
    return [];
  } catch (e) {
    console.error('Failed to parse OpenAI suggestions', e);
    return [];
  }
}
