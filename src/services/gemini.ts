import { GoogleGenAI, Type } from '@google/genai';

export async function getRhymeSuggestions(
  theme: string,
  lyrics: string,
  targetRhymeLine: string | null,
  rhymeType: string,
  rhymeScheme: string,
  currentLetter: string
): Promise<string[]> {
  const ai = new GoogleGenAI({ apiKey: process.env.GEMINI_API_KEY });

  const systemInstruction = `You are an expert songwriter and lyricist. Provide 5 creative, poetic, and contextually relevant suggestions for the next line of the user's song. Make sure the rhythm and meter match the style of the current lyrics${targetRhymeLine ? `, and strictly adhere to the requested rhyme type (${rhymeType})` : ''}.`;

  const userMessage = `The user is writing a song with the following theme/context: "${theme || 'No specific theme provided'}".
Here are the current lyrics:
"""
${lyrics}
"""

The user needs a line that follows the current lyrics.
The current stanza follows a "${rhymeScheme}" rhyme scheme, and the next line corresponds to the letter "${currentLetter}".
${targetRhymeLine 
  ? `Crucially, the new line MUST end with a **${rhymeType}** to this specific line: "${targetRhymeLine}".` 
  : `Since this is a new rhyme sound ("${currentLetter}"), the new line should introduce a new end-rhyme that fits the meter and theme.`}`;

  const response = await ai.models.generateContent({
    model: 'gemini-3.1-pro-preview',
    contents: userMessage,
    config: {
      systemInstruction: systemInstruction,
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
    throw new Error('Failed to parse rhyme suggestions from AI response');
  }
}
