import express from 'express';
import { GoogleGenAI, Type } from '@google/genai';
import * as dotenv from 'dotenv';

// Load environment variables if not already loaded
dotenv.config();

const app = express();
app.use(express.json());

const PORT = process.env.PORT || 3001;

app.post('/api/rhyme', async (req, res) => {
  try {
    const {
      theme,
      lyrics,
      targetRhymeLine,
      rhymeType,
      rhymeScheme,
      currentLetter
    } = req.body;

    // External service clients (e.g., GoogleGenAI) should be instantiated inside functions
    // rather than at the module level to ensure they are properly mockable
    const ai = new GoogleGenAI({ apiKey: process.env.GEMINI_API_KEY });

    const prompt = `
You are an expert songwriter and lyricist.
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
      const suggestions = JSON.parse(jsonStr);
      res.json(suggestions);
    } catch (parseError) {
      console.error('Failed to parse suggestions', parseError);
      // Prefer throwing errors in service layers to be handled by callers
      throw new Error('Failed to parse response from Gemini API');
    }
  } catch (error) {
    console.error('Error generating rhymes:', error);
    res.status(500).json({ error: 'Failed to generate rhymes' });
  }
});

app.listen(PORT, () => {
  console.log(`Server listening on port ${PORT}`);
});
