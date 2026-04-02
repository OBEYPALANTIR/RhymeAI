import { getRhymeSuggestionsGemini } from './gemini';
import { getRhymeSuggestionsOpenAI } from './openai';
import { getRhymeSuggestionsClaude } from './claude';

export type AIProvider = 'gemini' | 'openai' | 'claude';

const PROVIDER_KEY = 'lyricist-ai-provider';
const API_KEYS_KEY = 'lyricist-ai-keys';

export const PROVIDER_LABELS: Record<AIProvider, string> = {
  gemini: 'Google Gemini',
  openai: 'OpenAI',
  claude: 'Claude (Anthropic)',
};

export function getStoredProvider(): AIProvider {
  return (localStorage.getItem(PROVIDER_KEY) as AIProvider) || 'gemini';
}

export function setStoredProvider(provider: AIProvider): void {
  localStorage.setItem(PROVIDER_KEY, provider);
}

export function getStoredApiKey(provider: AIProvider): string {
  try {
    const keys = JSON.parse(localStorage.getItem(API_KEYS_KEY) || '{}');
    return keys[provider] || '';
  } catch {
    return '';
  }
}

export function setStoredApiKey(provider: AIProvider, key: string): void {
  try {
    const keys = JSON.parse(localStorage.getItem(API_KEYS_KEY) || '{}');
    keys[provider] = key;
    localStorage.setItem(API_KEYS_KEY, JSON.stringify(keys));
  } catch {
    localStorage.setItem(API_KEYS_KEY, JSON.stringify({ [provider]: key }));
  }
}

export async function getRhymeSuggestions(
  theme: string,
  lyrics: string,
  targetRhymeLine: string | null,
  rhymeType: string,
  rhymeScheme: string,
  currentLetter: string
): Promise<string[]> {
  const provider = getStoredProvider();
  const apiKey = getStoredApiKey(provider);

  if (!apiKey) {
    throw new Error(`No API key configured for ${PROVIDER_LABELS[provider]}. Open Settings to add your key.`);
  }

  switch (provider) {
    case 'gemini':
      return getRhymeSuggestionsGemini(apiKey, theme, lyrics, targetRhymeLine, rhymeType, rhymeScheme, currentLetter);
    case 'openai':
      return getRhymeSuggestionsOpenAI(apiKey, theme, lyrics, targetRhymeLine, rhymeType, rhymeScheme, currentLetter);
    case 'claude':
      return getRhymeSuggestionsClaude(apiKey, theme, lyrics, targetRhymeLine, rhymeType, rhymeScheme, currentLetter);
  }
}
