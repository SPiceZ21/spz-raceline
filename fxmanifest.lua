fx_version 'cerulean'
game 'gta5'

name 'spz-raceline'
description 'SPiceZ Raceline — auto-records your race and time-trial laps, stores the best-lap line per track, and paints it on the road (green = throttle, red = brake)'
version '0.4.0'
author 'SPiceZ-Core'
lua54 'yes'

shared_script 'config.lua'

client_scripts {
  'client/main.lua',
  'client/ghost.lua',
}

server_scripts {
  '@oxmysql/lib/MySQL.lua',
  'server/main.lua',
}

dependencies {
  'oxmysql',
}
