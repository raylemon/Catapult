extends Node


signal status_message
signal copy_dir_done
signal rm_dir_done
signal move_dir_done
signal extract_done


var _platform: String = ""

var last_extract_result: int = 0 setget , _get_last_extract_result
# Stores the exit code of the last extract operation (0 if successful).


func _enter_tree() -> void:
	
	_platform = OS.get_name()


func get_own_dir() -> String:
	# Returns the absolute path to the directory with the executable.
	
	return OS.get_executable_path().get_base_dir()


func _get_last_extract_result() -> int:
	
	return last_extract_result


func list_dir(path: String, recursive := false) -> Array:
	# Lists the files and subdirectories within a directory.
	
	var d = Directory.new()
	d.open(path)
	
	var error = d.list_dir_begin(true)
	if error:
		emit_signal("status_message", tr("msg_list_dir_failed") % [path, error], Enums.MSG_ERROR)
		return []
	
	var result = []
	
	while true:
		var name = d.get_next()
		if name:
			result.append(name)
			if recursive and d.current_is_dir():
				var subdir = list_dir(path.plus_file(name), true)
				for child in subdir:
					result.append(name.plus_file(child))
		else:
			break
	
	return result


func _copy_dir_internal(data: Array) -> void:
	
	var abs_path: String = data[0]
	var dest_dir: String = data[1]
	
	var dir = abs_path.get_file()
	var d = Directory.new()
	
	var error = d.make_dir_recursive(dest_dir.plus_file(dir))
	if error:
		emit_signal("status_message", tr("msg_cannot_create_target_dir")
				% [dest_dir.plus_file(dir), error], Enums.MSG_ERROR)
		return
	
	for item in list_dir(abs_path):
		var path = abs_path.plus_file(item)
		if d.file_exists(path):
			error = d.copy(path, dest_dir.plus_file(dir).plus_file(item))
			if error:
				emit_signal("status_message", tr("msg_copy_file_failed")
						% [item, error], Enums.MSG_ERROR)
				emit_signal("status_message", tr("msg_copy_file_failed_details")
						% [path, dest_dir.plus_file(dir).plus_file(item)])
		elif d.dir_exists(path):
			_copy_dir_internal([path, dest_dir.plus_file(dir)])


func copy_dir(abs_path: String, dest_dir: String) -> void:
	# Recursively copies a directory *into* a new location.
	
	var tfe = ThreadedFuncExecutor.new()
	tfe.execute(self, "_copy_dir_internal", [abs_path, dest_dir])
	yield(tfe, "func_returned")
	tfe.collect()
	emit_signal("copy_dir_done")


func _rm_dir_internal(data: Array) -> void:
	
	var abs_path = data[0]
	var d = Directory.new()
	var error
	
	for item in list_dir(abs_path):
		var path = abs_path.plus_file(item)
		if d.file_exists(path):
			error = d.remove(path)
			if error:
				emit_signal("status_message", tr("msg_remove_file_failed")
						% [item, error], Enums.MSG_ERROR)
				emit_signal("status_message", tr("msg_remove_file_failed_details")
						% path, Enums.MSG_DEBUG)
		elif d.dir_exists(path):
			_rm_dir_internal([path])
	
	error = d.remove(abs_path)
	if error:
		emit_signal("status_message", tr("msg_rm_dir_failed") % [abs_path, error], Enums.MSG_ERROR)


func rm_dir(abs_path: String) -> void:
	# Recursively removes a directory.
	
	var tfe = ThreadedFuncExecutor.new()
	tfe.execute(self, "_rm_dir_internal", [abs_path])
	yield(tfe, "func_returned")
	tfe.collect()
	emit_signal("rm_dir_done")


func _move_dir_internal(data: Array) -> void:
	
	var abs_path: String = data[0]
	var abs_dest: String = data[1]
	
	var d = Directory.new()
	var error = d.make_dir_recursive(abs_dest)
	if error:
		emit_signal("status_message", tr("msg_create_dir_failed") % [abs_dest, error], Enums.MSG_ERROR)
		return
	
	for item in list_dir(abs_path):
		var path = abs_path.plus_file(item)
		var dest = abs_dest.plus_file(item)
		if d.file_exists(path):
			error = d.rename(path, abs_dest.plus_file(item))
			if error:
				emit_signal("status_message", tr("msg_move_file_failed") % [item, error], Enums.MSG_ERROR)
				emit_signal("status_message", tr("msg_move_file_failed_details") % [path, dest])
		elif d.dir_exists(path):
			_move_dir_internal([path, abs_dest.plus_file(item)])
	
	error = d.remove(abs_path)
	if error:
		emit_signal("status_message", tr("msg_move_rmdir_failed") % [abs_path, error], Enums.MSG_ERROR)


func move_dir(abs_path: String, abs_dest: String) -> void:
	# Moves the specified directory (this is move with rename, so the last
	# part of dest is the new name for the directory).
	
	var tfe = ThreadedFuncExecutor.new()
	tfe.execute(self, "_move_dir_internal", [abs_path, abs_dest])
	yield(tfe, "func_returned")
	tfe.collect()
	emit_signal("move_dir_done")


func extract(path: String, dest_dir: String) -> void:
	# Extracts a .zip or .tar.gz archive using the system utilities on Linux
	# and bundled unzip.exe from InfoZip on Windows.
	
	var unzip_exe = get_own_dir().plus_file("utils").plus_file("unzip.exe")
	
	var command_linux_zip = {
		"name": "unzip",
		"args": ["-o", "\"\"%s\"\"" % path, "-d", "\"\"%s\"\"" % dest_dir]
	}
	var command_linux_gz = {
		"name": "tar",
		"args": ["-xzf", "\"\"%s\"\"" % path, "-C", "\"\"%s\"\"" % dest_dir,
				"--exclude=*doc/CONTRIBUTING.md", "--exclude=*doc/JSON_LOADING_ORDER.md"]
				# Godot can't operate on symlinks just yet, so we have to avoid them.
	}
	var command_windows = {
		"name": "cmd",
		"args": ["/C", "\"%s\" -o \"%s\" -d \"%s\"" % [unzip_exe, path, dest_dir]]
	}
	var command
	
	if (_platform == "X11") and (path.to_lower().ends_with(".tar.gz")):
		command = command_linux_gz
	elif (_platform == "X11") and (path.to_lower().ends_with(".zip")):
		command = command_linux_zip
	elif (_platform == "Windows") and (path.to_lower().ends_with(".zip")):
		command = command_windows
	else:
		emit_signal("status_message", tr("msg_extract_unsupported") % path.get_file(), Enums.MSG_ERROR)
		emit_signal("extract_done")
		return
		
	var d = Directory.new()
	if not d.dir_exists(dest_dir):
		d.make_dir_recursive(dest_dir)
		
	emit_signal("status_message", tr("msg_extracting_file") % path.get_file())
		
	var oew = OSExecWrapper.new()
	oew.execute(command["name"], command["args"])
	yield(oew, "process_exited")
	last_extract_result = oew.exit_code
	if oew.exit_code:
		emit_signal("status_message", tr("msg_extract_error") % oew.exit_code, Enums.MSG_ERROR)
		emit_signal("status_message", tr("msg_extract_failed_cmd") % str(command), Enums.MSG_DEBUG)
		emit_signal("status_message", tr("msg_extract_fail_output") % oew.output[0], Enums.MSG_DEBUG)
	emit_signal("extract_done")
