-- Settings: change it to false, to disable
convert_subs 		= true		-- change it to false if you don't want to download subs... (let VLC do what it wants)
force_h264 		= true		-- Useful on old hardware, set it to false for better (?) video quality
do_not_overlap		= true		-- Skip repeating previous line in YT autocaptions
def_sub_int 		= 0		-- seconds, change to 0 to disable. Maximum time interval to keep caption on screen.

-- Don't change these if you're not 100% sure what are you doing :)
thread_concurrency	= 5		-- number of 'threads' when downloading subtitles.
prefix 			= "vlcsub-"

-- ONLY FOR TESTING:
skip_auto_if_any	= true		-- Don't process auto translations if setting is 'any' (there can be 100+ cross-translations/video)

local ytdlp = { }
ytdlp.subext		= { srt = true, vtt = true } -- supported subtitle formats
ytdlp.pref_sublangs	= vlc.var.inherit( nil, "sub-language" ) 		-- subbtilte settings in Preferences->Sublbtitles/OSD
ytdlp.prefres 		= vlc.var.inherit( nil, "preferred-resolution" ) 	-- resolution settings in (all)Preferences->Input/Codecs

dbg, warn, err, info = "dbg", "warn", "err", "info"
function print( mode, ... )
	local msgs = { ... }
	if #msgs == 0 then 
		vlc.msg.err("function print: ... is EMPTY")
		return 
	end
	if mode == dbg or mode == warn or mode == err or mode == info then
		vlc.msg[ mode ]( ... )
	else
		vlc.msg.dbg( mode, ... )
	end
end

-- Pick the most suited format available
function ytdlp:get_fmt( res )
	local fmt = ''
	local codec = "codec:avc"
	--local codec = "+codec:avc:m4a"
	--local codec = "codec:avc:m4a"
	--local codec = "codec:h264"
	if res or ( self.prefres > 0 ) then
		if force_h264 then
			fmt = " -S \"res:%d,%s\" "
		else
			fmt = " -S \"res:%d\" "
		end
		return fmt:format( ( res or self.prefres ), codec)
	elseif force_h264 then  -- else yt-dlp's default selection (best)
		fmt = " -S \"%s\" "
		return fmt:format( codec )
	end
	return ""
end

function ytdlp:get_format_url( format )
	-- prefer streaming formats
	return format.manifest_url and format.manifest_url or format.url
end

function ytdlp:get_timecode( t, dur )
	return ( tonumber( dur or 0 ) > 3600 ) and os.date( "!%H:%M:%S - ", t ) or os.date( "%M:%S - ", t ) -- !UTC
end

_sep  = string.sub( package.config, 1, 1 ) -- '\' or '/'
function getTempPath( str )
	for _, env in ipairs { "TEMP", "TMPDIR" } do
		local temp = os.getenv( env )
		if temp then 
			--return temp .. _sep .. str
			return temp .. str
		end
	end
	return "/tmp/" .. str
end

function isWin()
	return _sep == "\\"
end

function vtt2srt( tbl )
	local self = { suburls = tbl, path = ytdlp.path }
	local input, err = vlc.stream( tbl.url )
	--print( err, "opening url: " .. tbl.url )
	if input then
		-- skipping live subs (no VLC support)
		if input:read(7) == "#EXTM3U" then
			print(err, "yt-dlp.lua: #EXTM3U found, SKIP")
			if _TESTING then
				input:close()
			end
			return
		---------------------------------------------------
		-- convert subtitles to srt (aka vtt2srt v1.3c)
		---------------------------------------------------
		elseif convert_subs then
			--print("Converting subtitle...")
			input:seek( 0 )
			local linenr = 0
			local out = { [0] = { } }
			local cueindex = 0
			local line = input:readline()
			local lastline = ''
			while line do
				if line ~= '' then
					if line:find("^[%s%d]*$") then
						--empty (line, or srt cue index) -> skip
					elseif ( line:sub( 1, 4 ) == "NOTE" or line:sub( 1, 5 ) == "STYLE" ) and linenr == 0 then
						--skipping notes and styling (if it's not part of the text 0.o)
						repeat
							line = input:readline()
						-- until we reach an empty line (or end of file)
						until not line or line == ''
						-- read next line (if not end of file)
						line = line and input:readline()
					else
						-- looking for a timecode (vtt and srt format as well) and make it srt style
						local start, stop = line:match( "^([0-9:%.,]+) ?%-%-> ?([0-9:%.,]+) ?" )
						if start and stop then
							-- UPDATE v1.3c: change the interval to a reasonble value..
							if def_sub_int > 0 then
								-- making comparable timestamps from timecode
								-- start
								local hour, min, sec = start:match( "(%d+):(%d+):(%d+)" )
								local now = os.time()
								local tstart = os.date( "*t", now )
								tstart.hour, tstart.min, tstart.sec = hour, min, sec
								-- stop
								hour, min, sec = stop:match( "(%d+):(%d+):(%d+)" )
								local tstop = os.date( "*t", now )
								tstop.hour, tstop.min, tstop.sec = hour, min, sec
								-- adjust stop if needed
								if os.difftime( os.time( tstop ), os.time( tstart ) ) > def_sub_int then
									stop = os.date( "%H:%M:%S", os.time( tstart ) + def_sub_int ) .. ",000"
								end
								----------------------------------------------------
							end
							local timecode = ( start .. " --> " .. stop ):gsub( "%.", ',' )
								--table.insert( out[cueindex], timecode )
								linenr = linenr+1
								rawset( out[ cueindex ], linenr, timecode )
						else
							-- <b></b>, <u></u> and <i></i> are valid tags in srt, we keep them...
							-- remove every other tags
							-- also remove leading hyphens (-) according to Mozilla's documentation
							-- https://developer.mozilla.org/en-US/docs/Web/API/WebVTT_API
							local cleanline = ( line ):gsub( "%b<>", function( tag )
									return tag:find( "</?[bui]>" ) and tag or ''
								end
							)
							cleanline = cleanline:gsub( "^- ", '' )
							-- UPDATE v1.3a: replace '&nbsp;' with space
							cleanline = cleanline:gsub( "&nbsp;", ' ' )

							if out[ cueindex ] then -- if not header?? I think it's always true...
								-- UPDATE v1.3b: option to prevent line overlaps
								if do_not_overlap and cleanline == lastline then
									--if the last line was the same, we skip...
								else
									lastline = cleanline
									--table.insert( out[ cueindex ], cleanline )
									linenr = linenr + 1
									rawset( out[ cueindex ], linenr, cleanline )
								end
							end
						end
					end
				else
					--got an empty line after a timecode -> start a new cue
					if linenr > 0 then
						if linenr > 1 then -- overwrite empty cue
							cueindex = cueindex + 1
						end
						out[ cueindex ] = { }
						linenr = 0
					end
				end

				coroutine.yield() -- yield to continue concurrent threads
				line = input:readline()
			end
			if _TESTING then -- io.open() support for testing
				input:close()
			end
			
			-- TODO: remove empty cue(s) at the end !!
			
			--write and done
			local ofName = self.path .. '.' .. tbl.lng .. ".srt"
			local output, e = io.open( ofName, "w+" )
			if output then
				--print("saving to file "..ofname)
				for i, v in ipairs(out) do
					output:write( i .. '\n' .. table.concat( v, '\n' ) .. "\n\n" )
				end
				output:close()
				-- self.suburls[i].url = ofname
				self.suburls.url = ofName
			else
				-- keep the url in the list (failback)
				print( err, "yt-dlp.lua cannot open " .. ofName .. " for writing: " .. e )
			end
		end
	else
		print( err, "yt-dlp.lua stream ERROR: " .. err )
		--self.suburls[ i ] = nil
		self.suburls = nil
	end
	return self.suburls
end


-- Parse function.
function parse()
	local self = ytdlp
	self.v_url = vlc.access .. "://" .. vlc.path -- get full url
	local tracks = { }

	-- Using yt-dlp 
	-- https://github.com/yt-dlp/yt-dlp
	-- 
	-- UPDATE: add oppurtunity to use custom resolution regardless of VLC settings:
	-- add '&res=X' to the end of the link....
	-- eg: https://youtu.be/V1dId&res=1080
	local s, e, res = string.find(self.v_url, "&res=(%d+)")
	if res then
		self.v_url = self.v_url:sub( 1, ( s - 1 ) ) .. self.v_url:sub( e + 1 )
	end

	local cmd = "yt-dlp --dump-json --flat-playlist " .. ytdlp:get_fmt( res ) .. " \"" .. self.v_url .."\""
	local file, tmp
	if isWin() then
		tmp = getTempPath( os.tmpname() )
		cmd =  'cmd /c "title Fetching video links, this can take a while ... && ' .. cmd:gsub( "&", "^&" ) .. ' > ' .. tmp .. '"'
		--print(err, tmp)
		--print(err, cmd)
		os.execute( cmd )
		file = assert( io.open( tmp ) )
	else
		file = assert( io.popen( cmd, 'r' ) )
	end
	-- if the link points to a playlist we need to iterate over each element
	local decode = require( "dkjson" ).decode -- load additional json routines
	while true do
		local line = file:read( "*l" )
		if not line then
			break
		end
		--print( err, "line:" .. line .. "|" )
		local json = decode( line )
		if not json then
			--local f = io.open( "~/error.out", "w+" )
			--f:write( line )
			--f:close()
			print( err, "ytdlp: JSON decode has failed" )
			break 
		end
		
		local outurl = json.url
		local out_includes_audio = true
		local audiourl = nil
		if not outurl then
			if json.requested_formats then --might be nil when we want the best available format
				for key, format in ipairs( json.requested_formats ) do
					if format.vcodec and format.vcodec ~= "none" then
						outurl = ytdlp:get_format_url( format )
						out_includes_audio = ( format.acodec and format.acodec ~= "none" )
					end

					if format.acodec and format.acodec ~= "none" then
						audiourl = ytdlp:get_format_url( format )
					end
				end
			else
				-- workaround of yt-dlp's format selection bug (in the past)
				-- we 'manually' select the requested format, looping backward (from best to worst)
				-- FIXME: ?
				local a_set, v_set = false, false
				local idx = #json.formats
				while ( not a_set and not v_set and idx > 0 ) do
					local format = json.formats[ idx ]
					idx = idx - 1
					
					if ( not v_set and ( format.vcodec and format.vcodec ~= "none" ) ) then
						-- choose best video
						outurl = ytdlp:get_format_url( format )
						v_set = true
						
						if ( format.acodec and format.acodec ~= "none" ) then
							-- prefer audio + video
							audiourl = ytdlp:get_format_url( format )
							out_includes_audio = true
							a_set = true
							break
						end
					end

					if ( not a_set and ( format.acodec and format.acodec ~= "none" ) ) then
						-- audio only
						audiourl = ytdlp:get_format_url( format )
						a_set = true
					end
				end
			end
		end

		if outurl or audiourl then
			--------------------------------------------------- 	  
			-- some metainfo stuff
			---------------------------------------------------
			local category, thumbnail, year
			if json.categories then
				category = json.categories[ 1 ]
			end

			if json.release_year then
				year = json.release_year
			elseif json.release_date then
				year = string.sub( json.release_date, 1, 4 )
			elseif json.upload_date then
				year = string.sub( json.upload_date, 1, 4 )
			end

			if json.thumbnails then
				thumbnail = json.thumbnails[ #json.thumbnails ].url
			end

			--------------------------------------------------------------------
			-- cleaning up metainfo + creating bookmarks
			--------------------------------------------------------------------
			local metainfo = { }
			local bookmarks
			local skip = { thumbnails_table = true, formats_table = true, description = true, urls = true } --subtitles_table = true, automatic_captions_table = true }
			for key, val in pairs( json ) do
				if key == "chapters" then
					bookmarks = { }
					for ci, cv in ipairs( val ) do
						table.insert( bookmarks, string.format( "{name=%s,time=%d}", ( ytdlp:get_timecode( cv.start_time, json.duration ) .. ( cv.title or "Chapter " .. ci ) ), cv.start_time ) )
					end
				elseif type( val ) ~= "table" and nil == skip[ key ] and key:sub( 1, 1 ) ~= '_' then
					metainfo[ key ] = tostring( val )
				end
			end
			if json.tags and #json.tags > 0 then
				metainfo.tags = table.concat( json.tags, '\n' )
			end
			metainfo.parser = json[ "_version"][ "repository" ] .. '@' .. json[ "_version" ][ "version" ]
			--metainfo.location = json.location or "unknown"
			
			local item = {
				path				= outurl and outurl or audiourl,
				name				= json.title,
				duration			= json.duration,

				-- for a list of these check https://code.videolan.org/videolan/vlc/-/blob/master/share/lua/README.txt  
				title				= json.track or json.title,
				artist				= json.artist or json.creator or json.uploader or json.playlist_uploader,
				genre				= json.genre or category,
				copyright			= json.license,
				album				= json.album or json.playlist_title or json.playlist,
				tracknum			= json.track_number or json.playlist_index,
				description			= json.description,
				rating				= json.average_rating,
				date					= year,
				setting				= json.location or "unknown",
			
				url				= json.webpage_url or self.v_url,
				arturl				= json.thumbnail or thumbnail,
				trackid				= json.track_id or json.episode_id or json.id,
				tracktotal			= json.n_entries or 300,
				season				= json.season or json.season_number or json.season_id,
				episode				= json.episode or json.episode_number,
				show_name			= json.series,

				meta				= metainfo,
				options				= { ":start-time=" .. ( json.start_time or 0 ) },
			}

--[[ --since we don't use the title to save temporary files anymore, this part is unneccesary
			-- 'escaping' / and \ chars.. 
			-- look at https://github.com/yt-dlp/yt-dlp/blob/master/test/test_YoutubeDL.py
			-- change of foo/bar\test to foo⧸bar⧹test
			-- urlencoded: foo%E2%A7%B8bar%E2%A7%B9test
			--FIXME: possibly more chars to replace ( *, ?, whatever)
			local esc = {['/'] = string.char(0xe2)..string.char(0xa7)..string.char(0xb8), ['\\'] = string.char(0xe2)..string.char(0xa7)..string.char(0xb9)}
			item.title = string.gsub(item.title, '(%p)', function(c) return esc[c] or c end)
]]			
			local input_slave = { }
			---------------------------------------------------
			-- add optional audio
			---------------------------------------------------
			if not out_includes_audio and audiourl and outurl ~= audiourl then
				table.insert(input_slave, audiourl)
			end
			---------------------------------------------------
			-- add bookmarks
			---------------------------------------------------
			if bookmarks then
				table.insert( item.options, ":bookmarks=\"" .. table.concat( bookmarks, ',' ) .. "\"")
			end
			---------------------------------------------------
			-- add subtitles
			---------------------------------------------------
			self.suburls = { } -- { {['lng'] = 'nl', ['url'] = 'https://url.com', ['ext'] = 'vtt'} } 
			
			-- Don't load any subtitles if it's not set in the settings
			if self.pref_sublangs ~= '' then
				self.preflang = { }
				-- if we want all subs ...
				if self.pref_sublangs == "any" then
					self.preflang[ "all" ] = 1
					self.preflang[ 1 ] = "all"
				-- if we want selected subs
				else
					for cc in string.gmatch( self.pref_sublangs, "%w%w" ) do
						table.insert( self.preflang, cc ) -- used for table.concat()...
						self.preflang[ cc ] = #self.preflang -- used as index in self.suburls
					end
				end
			end
			---------------------------------------------------
			-- Select the needed subtitles
			---------------------------------------------------
			-- "normal" subtitles
			if self.preflang and json.subtitles then
				for lng, val in pairs( json.subtitles ) do
					if self.preflang[ lng ] or self.preflang[ "all" ] then
						for i, v in pairs( val ) do
							if self.subext[ v.ext ] then
								local index = self.preflang[ lng ] or ( #self.suburls + 1 )
								self.suburls[ index ] = { lng = lng, url = v.url, ext = v.ext }
							end
						end
					end
				end
			end
			---------------------------------------------------
			-- auto captions / translations
			---------------------------------------------------
			if self.preflang and json.automatic_captions then
				for lng, val in pairs( json.automatic_captions ) do
					-- NOTE: skipping 'all' here, also we don't replace human captions with auto ones
					local auto = true
					if skip_auto_if_any then
						auto = self.preflang[ lng ]
					end
					if auto and not self.suburls[ self.preflang[ lng ] ] then
						if val.url then -- simple array
							if self.subext[ val.ext ] then
								local index = self.preflang[ lng ] or ( #self.suburls + 1 )
								self.suburls[ index ] = { lng = lng, url = val.url, ext = val.ext }
							end
						else -- multi array
							for i, v in ipairs( val ) do
								if self.subext[ v.ext ] then
									local index = self.preflang[ lng ] or ( #self.suburls + 1 )
									self.suburls[ index ] = { lng = lng, url = v.url, ext = v.ext }
								end
							end
						end
					end
				end
			end
			
			---------------------------------
			-- process subtitles
			--------------------------------
			if self.pref_sublangs ~= '' then 
				self.path = getTempPath( prefix ) ..  item.trackid
				
				-- Processing subs
				-- Using coroutines to save some time :p
				local co = { }

				local function startThread( worker, tbl )
					local res, err = coroutine.resume( worker, tbl )
					if res then
						--print( err,"creating thread " .. i )
						table.insert( co, worker )
					--else
						--print( err, "Failed to create thread " .. tostring( err ) .. " ( " .. tostring( tbl.url ) .. " )" )
					end
				end

				local queue = { }
				for i, tbl in ipairs( self.suburls ) do -- ipairs !!
					local worker = coroutine.create( vtt2srt )
					if #co < thread_concurrency then
						startThread( worker, tbl )
						--print( err, "Started thread " .. tbl.lng )
					else
						table.insert( queue, { worker = worker, tbl = tbl } )
						--print( err, "Queued thread " .. tbl.lng )
					end
				end
				local queueIdx, queueSize = 1, #queue
				
				-- reset the table
				self.suburls = { }
				
				-- process them
				while ( #co > 0 ) do
					local threads = co
					co = { }
					for i = 1, #threads do
						local thing = threads[ i ]
						if coroutine.status( thing ) ~= "dead" then
							local res, ret = coroutine.resume( thing )
							if res then -- thread is OK
								if ret then -- got results, thread has been finished
									table.insert( self.suburls, ret )
									--print( err, "SUB OKAY: " .. ret.url )
								else -- continue the thread
									table.insert( co, thing )
								end
							--else
								--print( err, "res, ret: ".. tostring( res ) .. ", ".. tostring( ret ) )
							end
						end
					end
					-- process the queue if possible
					while ( ( #co < thread_concurrency ) and ( queueSize > 0 ) ) do
						local job = queue[ queueIdx ]
						queue[ queueIdx ] = nil
						queueIdx = queueIdx + 1
						queueSize = queueSize - 1
						startThread( job.worker, job.tbl )
					end
				end

				for i, tbl in ipairs( self.suburls ) do
					table.insert( input_slave, tbl.url ) -- url can be web link or local file path too.
				end
			end
			if #input_slave > 0 then
				table.insert( item.options, ":input-slave=" .. table.concat( input_slave, '#' ) )
			end
			-- Finally add the track to the playlist
			table.insert( tracks, item )
		end
	end --while
	file:close()
	if tmp then --cleanup
		pcall(os.remove, tmp)
	end
	return tracks
end

-- Probe function.
function probe()
	--if true then return false end
	if vlc.access == "http" or vlc.access == "https" then
		local peeklen = 9
		local str = ''
		while #str < 9 and peeklen < 64 do --prevent infinite loop
			str = vlc.peek( peeklen ):gsub( "%s", '' )
			peeklen = peeklen + 1
		end
		return string.lower( str ) == "<!doctype" -- peeklen
	end
	return false
end
