require('dotenv').config();

const config = {
  port: process.env.PORT || 3555,
  serviceName: process.env.SERVICE_NAME || 'Jellyfin WhatsApp Bot',

  whatsapp: {
    owner: process.env.WHATSAPP_OWNER || '',
    updateNotifyToken: process.env.WHATSAPP_UPDATE_NOTIFY_TOKEN || '',
  },

  admin: {
    registerCode: process.env.ADMIN_REGISTER_CODE || '',
    botToken: process.env.BOT_ADMIN_TOKEN || '',
  },

  webhooks: {
    uptimeKumaSecret: process.env.UPTIME_KUMA_SECRET || '',
  },

  adguard: {
    url: process.env.ADGUARD_URL || 'http://chae-adguard:3000',
    username: process.env.ADGUARD_USERNAME || '',
    password: process.env.ADGUARD_PASSWORD || '',
  },

  jellyfin: {
    url: process.env.JELLYFIN_URL || '',
    apiKey: process.env.JELLYFIN_API_KEY || '',
    userId: process.env.JELLYFIN_USER_ID || '',
  },

  radarr: {
    url: process.env.RADARR_URL || '',
    apiKey: process.env.RADARR_API_KEY || '',
    rootFolder: process.env.RADARR_ROOT_FOLDER || '/movies',
    qualityProfileId: parseInt(process.env.RADARR_QUALITY_PROFILE_ID) || 1,
    minimumAvailability: process.env.RADARR_MINIMUM_AVAILABILITY || 'released',
    secret: process.env.RADARR_SECRET || '',
  },

  sonarr: {
    url: process.env.SONARR_URL || '',
    apiKey: process.env.SONARR_API_KEY || '',
    rootFolder: process.env.SONARR_ROOT_FOLDER || '/series',
    qualityProfileId: parseInt(process.env.SONARR_QUALITY_PROFILE_ID) || 1,
    languageProfileId: parseInt(process.env.SONARR_LANGUAGE_PROFILE_ID) || 1,
    secret: process.env.SONARR_SECRET || '',
  },

  qbittorrent: {
    url: process.env.QBITTORRENT_URL || '',
    username: process.env.QBITTORRENT_USERNAME || '',
    password: process.env.QBITTORRENT_PASSWORD || '',
  },

  jellyseerr: {
    url: process.env.JELLYSEERR_URL || '',
    apiKey: process.env.JELLYSEERR_API_KEY || '',
  },

  bazarr: {
    url: process.env.BAZARR_URL || '',
    apiKey: process.env.BAZARR_API_KEY || '',
  },

  prowlarr: {
    url: process.env.PROWLARR_URL || '',
    apiKey: process.env.PROWLARR_API_KEY || '',
  },

  tmdb: {
    apiKey: process.env.TMDB_API_KEY || '',
    accessToken: process.env.TMDB_ACCESS_TOKEN || '',
  },
};

module.exports = config;
