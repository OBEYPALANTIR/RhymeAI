import { GoogleGenAI, Type } from '@google/genai';

const ai = new GoogleGenAI({ apiKey: process.env.GEMINI_API_KEY });

export async function getRhymeSuggestions(
  theme: string,
  lyrics: string,
  currentLine: string,
  rhymeType: string
): Promise<string[]> {
  const prompt = `
You are an expert songwriter and lyricist.
The user is writing a song with the following theme/context: "${theme || 'No specific theme provided'}".
Here are the current lyrics:
"""
${lyrics}
"""

The user needs a line that follows the current lyrics.
Crucially, the new line MUST end with a **${rhymeType}** to this specific line: "${currentLine}".
Provide 5 creative, poetic, and contextually relevant suggestions for the next line.
Make sure the rhythm and meter match the style of the current lyrics, and strictly adhere to the requested rhyme type (${rhymeType}).
`;

  const response = await ai.models.generateContent({
    model: 'gemini-3.1-pro-preview',
    contents: prompt,
    config: {
      responseMimeType: 'application/json',
      responseSchema: {
        type: Type.ARRAY,
        items: {
          type: Type.STRING,
        },
        description: 'An array of 5 suggested lines.',
      },
    },
  });

  try {
    const jsonStr = response.text?.trim() || '[]';
    return JSON.parse(jsonStr);
  } catch (e) {
    console.error('Failed to parse suggestions', e);
    return [];
  }
}
