fx_version 'cerulean'
game 'gta5'

name 'spz-raceline'
description 'SPiceZ Raceline — capture your driving line and paint it on the road (green = throttle, red = brake); stores your best-lap line per time-trial track'
version '0.2.0'
author 'SPiceZ-Core'
lua54 'yes'

shared_script 'config.lua'

client_scripts {
  'client/main.lua',
}

server_scripts {
  '@oxmysql/lib/MySQL.lua',
  'server/main.lua',
}

dependencies {
  'oxmysql',
}
