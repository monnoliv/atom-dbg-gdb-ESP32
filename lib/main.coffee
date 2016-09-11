parseMi2 = require './parseMi2'
{BufferedProcess, CompositeDisposable, Emitter} = require 'atom'

window.test = parseMi2

module.exports = DbgGdb =
	dbg: null
	breakpoints: []
	ui: null
	process: null
	processAwaiting: false
	processQueued: []
	thread: 1
	frame: 0
	outputPanel: null
	miEmitter: new Emitter()

	activate: (state) ->
		@disposable = new CompositeDisposable
		@disposable.add atom.commands.add '.tree-view .file', 'dbg-gdb:debug-file': =>
			if !@dbg then return
			selectedFile = document.querySelector '.tree-view .file.selected [data-path]'
			if selectedFile!=null
				@dbg.debug
					debugger: 'dbg-gdb'
					path: selectedFile.dataset.path
					cwd: (require 'path').dirname(selectedFile.dataset.path)
					args: []

	deactivate: ->
		@disposable.dispose()

	consumeOutputPanel: (outputPanel) ->
		@outputPanel = outputPanel

	debug: (options, api) ->
		matchAsyncHeader = /^([\^=*+])(.+?)(?:,(.*))?$/
		matchStreamHeader = /^([~@&])(.*)?$/

		@ui = api.ui
		@breakpoints = api.breakpoints
		@outputPanel?.clear()

		outputRevealed = @outputPanel?.isVisible();

		# @process = @outputPanel.run true, 'lldb-mi', ['-o','run',options.path,'--'].concat(options.args), {
		@process = new BufferedProcess
			command: 'gdb'
			args: ['-quiet','--interpreter=mi2']
			options:
				cwd: options.cwd
			stdout: (data) =>
				for line in data.replace(/\n$/,'').split('\n')
					if match = line.match matchAsyncHeader
						type = match[2]
						data = if match[3] then parseMi2 match[3] else {}
						switch match[1]
							when '^' then @miEmitter.emit 'result' , {type:type, data:data}
							when '=' then @miEmitter.emit 'notify' , {type:type, data:data}
							when '*' then @miEmitter.emit 'exec'	 , {type:type, data:data}
							when '+' then @miEmitter.emit 'status' , {type:type, data:data}
					else if match = line.match matchStreamHeader
						data = parseMi2 match[2]
						data = if data then data._ else ''
						switch match[1]
							when '~' then @miEmitter.emit 'console', data
					else
						if @outputPanel and line!='(gdb)' and line!='(gdb) '
							if !outputRevealed
								outputRevealed = true
								@outputPanel.show()
							@outputPanel.print line

			exit: (data) =>
				@miEmitter.emit 'exit'

		@processAwaiting = false
		@processQueued = []

		@miEmitter.on 'exit', =>
			@ui.stop()

		@miEmitter.on 'console', (line) =>
			@outputPanel?.print line

		@miEmitter.on 'result', ({type, data}) =>
			switch type
				when 'running'
					@ui.running()

		@miEmitter.on 'exec', ({type, data}) =>
			switch type
				when 'running'
					@ui.running()

				when 'stopped'
					if data.reason == 'exited-normally'
						@ui.stop()
						return

					@ui.paused()

					@sendMiCommand 'stack-list-frames --thread '+@thread
						.then ({type, data}) =>
							stack = []
							lastValid = false
							@stackList = data.stack
							if data.stack.length>0 then for i in [0..data.stack.length-1]
								frame = data.stack[i]
								description

								name = ''
								if frame.func
									name = frame.func
								else
									name = frame.addr

								path = ''
								if frame.file
									path = frame.file.replace /^\.\//, ''
									if frame.line then path += ':'+frame.line
								else
									path = frame.from
									if frame.addr
										path += ':'+frame.addr

								description = name + ' - ' + path

								isLocal = frame.file && frame.file.match /^\.\//

								if isLocal and lastValid==false #get the first valid as the last, as this list is reversed
									lastValid = i

								stack.unshift
									local: isLocal
									file: frame.fullname
									line: if frame.line then parseInt(frame.line) else undefined
									name: name
									path: path

							@ui.setStack stack
							# if lastValid!=false
							# 	@frame = lastValid
							# 	@ui.setFrame stack.length-1-lastValid #reverse it
							# 	@refreshFrame()

							@frame = 0
							@refreshFrame()

		@sendMiCommand 'gdb-set mi-async on'
			.catch =>
				@sendMiCommand 'gdb-set target-async on'
					.catch (error) =>
						@handleMiError error, 'Unable to debug this with GDB'
						@dbg.stop()

			.then =>
				@sendMiCommand 'file-exec-and-symbols '+options.path
					.then =>
						for breakpoint in @breakpoints
							@sendMiCommand 'break-insert '+breakpoint.path+':'+breakpoint.line

						@sendMiCommand 'exec-run'
							.catch (error) =>
								@handleMiError error, 'Unable to debug this with GDB'
								@dbg.stop()

					.catch (error) =>
						if error.match /not in executable format/
							atom.notifications.addError 'This file cannot be debugged',
								description: 'It is not recognised as an executable file'
								dismissable: true
						else
							@handleMiError error, 'Unable to debug this with GDB'
						@dbg.stop()

	stop: ->
		@process?.kill();
		@process = null
		@processAwaiting = false
		@processQueued = []

	continue: ->
		@sendMiCommand 'exec-continue --all'
			.catch (error) => @handleMiError error

	pause: ->
		@sendMiCommand 'exec-interrupt --all'
			.catch (error) => @handleMiError error

	selectFrame: (index) ->
		reversedIndex = @stackList.length-1-index
		@frame = reversedIndex
		@ui.setFrame index
		@refreshFrame()

	selectThread: (index) ->
		@thread = index
		@ui.setThread index
		@refreshFrame()

	refreshFrame: ->
		@sendMiCommand 'stack-list-variables --thread '+@thread+' --frame '+@frame+' 2'
			.catch (error) => @handleMiError error
			.then ({type, data}) =>
				variables = []
				if data.variables
					for variable in data.variables
						variables.push
							name: variable.name
							type: variable.type
							value: variable.value
				@ui.setVariables variables

	stepIn: ->
		@sendMiCommand 'exec-step'
			.catch (error) => @handleMiError error

	stepOver: ->
		@sendMiCommand 'exec-next'
			.catch (error) => @handleMiError error

	stepOut: ->
		@sendMiCommand 'exec-finish'
			.catch (error) => @handleMiError error

	sendMiCommand: (command) ->
		if @processAwaiting
			return new Promise (resolve, reject) =>
				@processQueued.push =>
					@sendMiCommand command
						.then resolve, reject

		# console.log '< '+command
		@processAwaiting = true
		promise = Promise.race [
			new Promise (resolve, reject) =>
				event = @miEmitter.on 'result', ({type, data}) =>
					# console.log '> ',type,data
					event.dispose()
					# "done", "running" (same as done), "connected", "error", "exit"
					# https://sourceware.org/gdb/onlinedocs/gdb/GDB_002fMI-Result-Records.html#GDB_002fMI-Result-Records
					if type=='error'
						reject data.msg||'Unknown GDB error'
					else
						resolve {type:type, data:data}
			,new Promise (resolve, reject) =>
				event = @miEmitter.on 'exit', =>
					event.dispose()
					reject 'Debugger terminated'
		]
		promise.then =>
			@processAwaiting = false
			if @processQueued.length > 0
				@processQueued.shift()()
		, =>
			@processAwaiting = false
			if @processQueued.length > 0
				@processQueued.shift()()

		@process.process.stdin.write '-'+command+'\r\n', binary: true
		return promise

	handleMiError: (error, title) ->
		atom.notifications.addError title||'Error received from GDB',
			description: 'GDB said:\n\n> '+error.trim().split('\n').join('\n\n> ')
			dismissable: true

	addBreakpoint: (breakpoint) ->
		@breakpoints.push breakpoint
		@sendMiCommand 'break-insert '+breakpoint.path+':'+breakpoint.line

	removeBreakpoint: (breakpoint) ->
		for i,compare in @breakpoints
			if compare==breakpoint
				@breakpoints.splice i,1

		@sendMiCommand 'break-list'
			.then ({type, data}) =>
				if data.BreakpointTable
					for entry in data.BreakpointTable.body
						if entry.fullname==breakpoint.path and parseInt(entry.line)==breakpoint.line
							@sendMiCommand 'break-delete '+entry.number
								.catch (error) => @handleMiError error

	provideDbgProvider: ->
		name: 'dbg-gdb'
		description: 'GDB debugger'

		canHandleOptions: (options) =>
			return new Promise (fulfill, reject) =>
				fulfill true

		debug: @debug.bind this
		stop: @stop.bind this

		continue: @continue.bind this
		pause: @pause.bind this

		selectFrame: @selectFrame.bind this

		stepIn: @stepIn.bind this
		stepOver: @stepOver.bind this
		stepOut: @stepOut.bind this

		addBreakpoint: @addBreakpoint.bind this
		removeBreakpoint: @removeBreakpoint.bind this

	consumeDbg: (dbg) ->
		@dbg = dbg