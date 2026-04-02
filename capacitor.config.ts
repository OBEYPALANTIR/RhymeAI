import type { CapacitorConfig } from '@capacitor/cli';

const config: CapacitorConfig = {
  appId: 'com.lyricistai.app',
  appName: 'Lyricist AI',
  webDir: 'dist',
  server: {
    allowNavigation: [
      'generativelanguage.googleapis.com',
      'api.openai.com',
      'api.anthropic.com',
    ],
  },
  android: {
    allowMixedContent: true,
  },
};

export default config;
