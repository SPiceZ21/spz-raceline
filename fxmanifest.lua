fx_version 'cerulean'
game 'gta5'

name 'spz-raceline'
description 'SPiceZ Raceline — auto-records your race and time-trial laps, stores the best-lap line per track, and paints it on the road (green = throttle, red = brake)'
version '0.4.0'
author 'SPiceZ-Core'
lua54 'yes'

shared_scripts {
  '@ox_lib/init.lua',
  'config.lua',
}

client_scripts {
  'client/motion.lua',      -- must load first: defines RL_Mot* / RL_QuatSlerp
  'client/motion_pack.lua', -- binary packing (needs RL_MotLayout)
  'client/vehspec.lua',     -- RL_SpecCapture / RL_SpecApply
  'client/main.lua',
  'client/ghost.lua',
  'client/crown.lua',
}

server_scripts {
  '@oxmysql/lib/MySQL.lua',
  'server/main.lua',
  'server/crown.lua',
  'server/tax.lua',
  'server/botlines.lua',
}

dependencies {
  'oxmysql',
  'ox_lib',
}
