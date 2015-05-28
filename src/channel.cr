class SSH2::Channel
  include IO

  PROCESS_SHELL = "shell"
  PROCESS_EXEC = "exec"
  PROCESS_SUBSYSTEM = "subsystem"

  getter session

  def initialize(@session, @handle: LibSSH2::Channel)
    raise SSH2Error.new "invalid handle" unless @handle
  end

  # Close an active data channel. In practice this means sending an
  # SSH_MSG_CLOSE packet to the remote host which serves as instruction that no
  # further data will be sent to it. The remote host may still send data back
  # until it sends its own close message in response. To wait for the remote
  # end to close its connection as well, follow this command with
  # `wait_closed` or pass `wait` parameter as true.
  def close(wait = false)
    ret = LibSSH2.channel_close(self)
    check_error(ret).tap do
      wait_closed if wait
    end
  end

  def wait_closed
    ret = LibSSH2.channel_wait_closed(self)
    check_error(ret)
  end

  # Check if the remote host has sent an EOF status for the selected stream.
  def eof?
    LibSSH2.channel_eof(self) == 1
  end

  # Start shell
  def shell
    process_startup(PROCESS_SHELL, nil)
  end

  # Start a specified command
  def command(command)
    process_startup(PROCESS_EXEC, command)
  end

  # Start a specified subsystem
  def subsystem(subsystem)
    process_startup(PROCESS_SUBSYSTEM, subsystem)
  end

  def process_startup(request, message)
    ret = LibSSH2.channel_process_startup(self, request, request.bytesize.to_u32,
                                          message, message ? message.bytesize.to_u32 : 0_u32)
    check_error(ret)
  end

  # Flush channel
  def flush
    ret = LibSSH2.channel_flush(self, 0)
    check_error(ret)
  end

  # Flush stderr
  def flush_stderr
    ret = LibSSH2.channel_flush(self, LibSSH2::SSH_EXTENDED_DATA_STDERR)
    check_error(ret)
  end

  # Flush all substreams
  def flush_all
    ret = LibSSH2.channel_flush(self, LibSSH2::CHANNEL_FLUSH_ALL)
    check_error(ret)
  end

  # Flush all extended data substreams
  def flush_extended_data
    ret = LibSSH2.channel_flush(self, LibSSH2::CHANNEL_FLUSH_EXTENDED_DATA)
    check_error(ret)
  end

  # Return a tuple with first field populated with the exit signal (without
  # leading "SIG"), and the second field populated with the error message.
  def exit_signal
    ret = LibSSH2.channel_get_exit_signal(self, out exitsignal, out exitsignal_len,
                                          out errmsg, out errmsg_len, nil, nil)
    check_error(ret)
    exitsignal_str = String.new(exitsignal, exitsignal_len) if exitsignal
    errmsg_str = String.new(errmsg, errmsg_len) if errmsg
    {exitsignal_str, errmsg_str}
  end

  # LibSSH2::ExtendedData::NORMAL - Queue extended data for eventual reading 
  # LibSSH2::ExtendedData::MERGE  - Treat extended data and ordinary data the
  # same. Merge all substreams such that calls to `read`, will pull from all
  # substreams on a first-in/first-out basis.
  # LibSSH2::ExtendedData::IGNORE - Discard all extended data as it arrives.
  def handle_extended_data(ignore_mode: LibSSH2::ExtendedData)
    ret = LibSSH2.channel_handle_extended_data(self, ignore_mode)
    check_error(ret)
  end

  def read(slice: Slice(UInt8), length)
    ret = LibSSH2.channel_read(self, 0, slice.pointer(length), LibC::SizeT.cast(length))
    check_error(ret)
  end

  def read_stderr(slice: Slice(UInt8), length)
    ret = LibSSH2.channel_read(self, LibSSH2::SSH_EXTENDED_DATA_STDERR, slice.pointer(length), LibC::SizeT.cast(length))
    check_error(ret)
  end

  def write(slice: Slice(UInt8), length)
    ret = LibSSH2.channel_write(self, 0, slice.pointer(length), LibC::SizeT.cast(length))
    check_error(ret)
  end

  def write_stderr(slice: Slice(UInt8), length)
    ret = LibSSH2.channel_write(self, LibSSH2::SSH_EXTENDED_DATA_STDERR, slice.pointer(length), LibC::SizeT.cast(length))
    check_error(ret)
  end

  # Adjust the receive window for a channel by adjustment bytes. If the amount
  # to be adjusted is less than `LibSSH2::CHANNEL_MINADJUST` and force is false the
  # adjustment amount will be queued for a later packet.
  # Returns a new size of the receive window (as understood by remote end).
  def receive_window_adjust(adjustment, force = false)
    ret = LibSSH2.channel_receive_window_adjust(self, adjustment, force ? 1_u8 : 0_u8, out window)
    check_error(ret)
    window
  end

  # Request a PTY on an established channel. Note that this does not make sense
  # for all channel types and may be ignored by the server despite returning
  # success.
  def request_pty(term, modes, width, height, width_px, height_px)
    ret = LibSSH2.channel_request_pty(self, term, term.bytesize.to_u32, modes, modes.bytesize.to_u32,
                                   width, height, width_px, height_px)
    check_error(ret)
  end

  # Tell the remote host that no further data will be sent on the specified
  # channel. Processes typically interpret this as a closed stdin descriptor.
  def send_eof(wait = false)
    ret = LibSSH2.channel_send_eof(self)
    check_error(ret).tap do
      wait_eof if wait
    end
  end

  # Wait for the remote end to acknowledge an EOF request.
  def wait_eof
    ret = LibSSH2.channel_wait_eof(self)
    check_error(ret)
  end

  # Set an environment variable in the remote channel's process space. Note
  # that this does not make sense for all channel types and may be ignored by
  # the server despite returning success.
  def setenv(varname, value)
    ret = LibSSH2.channel_setenv(self, varname, varname.bytesize.to_u32, value, value.bytesize.to_u32)
    check_error(ret)
  end

  # The number of bytes which the remote end may send without overflowing the window limit
  def window_read
    LibSSH2.channel_window_read(self, nil, nil)
  end

  # Check the status of the write window Returns the number of bytes which may
  # be safely written on the channel without blocking.
  def window_write
    LibSSH2.channel_window_write(self, nil)
  end

  def finalize
    LibSSH2.channel_free(@handle)
  end

  def to_unsafe
    @handle
  end

  private def check_error(code)
    SessionError.check_error(@session, code)
  end

  struct IOErr
    include IO

    def initialize(@channel)
    end

    def read(slice: Slice(UInt8), length)
      @channel.read_stderr(slice, length)
    end

    def write(slice: Slice(UInt8), length)
      @channel.write_stderr(slice, length)
    end

    def flush
      @channel.flush_stderr
    end
  end

  def io_err
    IOErr.new(self)
  end
end