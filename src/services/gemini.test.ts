import { describe, it, expect, mock, beforeEach } from 'bun:test';
import { getRhymeSuggestions } from './gemini';

// Setup mock before tests run
const mockGenerateContent = mock(async () => {
  return {
    text: '["line 1", "line 2", "line 3", "line 4", "line 5"]'
  };
});

mock.module('@google/genai', () => {
  return {
    GoogleGenAI: class {
      models = {
        generateContent: mockGenerateContent
      };
    },
    Type: {
      ARRAY: 'ARRAY',
      STRING: 'STRING'
    }
  };
});

describe('getRhymeSuggestions', () => {
  beforeEach(() => {
    mockGenerateContent.mockClear();
  });

  it('separates system instructions from user inputs', async () => {
    const suggestions = await getRhymeSuggestions(
      'Love',
      'Roses are red',
      null,
      'perfect',
      'AABB',
      'B'
    );

    expect(suggestions).toEqual(['line 1', 'line 2', 'line 3', 'line 4', 'line 5']);

    // Check that generateContent was called once
    expect(mockGenerateContent).toHaveBeenCalledTimes(1);

    // Retrieve the call arguments
    const callArgs = mockGenerateContent.mock.calls[0][0];

    // Assert that 'contents' is set to the user message
    expect(callArgs.contents).toContain('The user is writing a song with the following theme/context: "Love"');
    expect(callArgs.contents).toContain('Roses are red');

    // Assert that 'config.systemInstruction' is set
    expect(callArgs.config.systemInstruction).toContain('You are an expert songwriter and lyricist.');
    expect(callArgs.config.systemInstruction).toContain('Provide 5 creative');

    // Ensure system instructions aren't leaking into the user contents
    expect(callArgs.contents).not.toContain('You are an expert songwriter and lyricist.');
  });

  it('throws an error if the model returns invalid JSON', async () => {
    mockGenerateContent.mockImplementationOnce(async () => {
      return { text: 'Invalid JSON' };
    });

    expect(getRhymeSuggestions(
      'Love',
      'Roses are red',
      null,
      'perfect',
      'AABB',
      'B'
    )).rejects.toThrow('Failed to parse rhyme suggestions from AI response');
  });

  it('throws an error if the model throws an error', async () => {
    mockGenerateContent.mockImplementationOnce(async () => {
      throw new Error('API Error');
    });

    expect(getRhymeSuggestions(
      'Love',
      'Roses are red',
      null,
      'perfect',
      'AABB',
      'B'
    )).rejects.toThrow('API Error');
  });
});
