export async function getRhymeSuggestions(
  theme: string,
  lyrics: string,
  targetRhymeLine: string | null,
  rhymeType: string,
  rhymeScheme: string,
  currentLetter: string
): Promise<string[]> {
  try {
    const response = await fetch('/api/rhyme', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        theme,
        lyrics,
        targetRhymeLine,
        rhymeType,
        rhymeScheme,
        currentLetter,
      }),
    });

    if (!response.ok) {
      throw new Error(`Failed to fetch rhymes: ${response.status} ${response.statusText}`);
    }

    return await response.json();
  } catch (error) {
    console.error('Error fetching rhymes from backend', error);
    return [];
  }
}
