# EMC Confidential Information, protected under EMC Bilateral Non-Disclosure Agreement.
# Copyright © 2012 EMC Corporation, All Rights Reserved

require "json"
require "pp"

# Root namespace for LogViewer objects
# used to find them in object space for type checking
LOGVIEWER_PREFIX = "ProjectRazor::LogViewer::"

# do a bit of "monkey-patching" of the File class so that we'll have access to a few
# additional methods from within our Logviewer Slice
class File

  # First, define a buffer size that is used for reading the file in chunks
  # in the each_chunk and tail methods, below
  BUFFER_SIZE = 4096

  # and define the default number of lines to include in a "tail" if not
  # specified in the input to the "tail" function (or if the value that
  # is passed in is a nil value)
  DEFAULT_NLINES_TAIL = 10

  # Here, we extend the File class with a new method (each_chunk) that can
  # be used to iterate through a file and return that file to the caller
  # in chunks of "chunk_size" bytes
  #
  # @param [Integer] chunk_size
  # @return [Object]
  def each_chunk(chunk_size=BUFFER_SIZE)
    yield read(chunk_size) until eof?
  end

  # Here, we extend the File class with a new method (tail) that will return
  # the last N lines from the corresponding file to the caller (as an array)
  #
  # @param [Integer] num_lines - the number of lines to read from from the "tail" of
  # the file (defaults to DEFAULT_NLINES_TAIL lines if not included in the method call)
  # @return [Array]  the last N lines from the file, where N is the input argument
  # (or the entire file if the number of lines is less than N)
  def tail(num_lines=DEFAULT_NLINES_TAIL)
    # if the number of lines passed in is nil, use the default value instead
    num_lines = DEFAULT_NLINES_TAIL unless num_lines
    # initialize a few variables
    idx = 0
    bytes_read = 0
    next_buffer_size = BUFFER_SIZE
    # handle the case where the file size is less than the BUFFER_SIZE
    # correctly (in that case, will read the entire file in one chunk)
    if size > BUFFER_SIZE
      idx = (size - BUFFER_SIZE)
    else
      next_buffer_size = size
    end
    chunks = []
    lines = 0
    # As long as we haven't read the number of lines requested
    # and we haven't read the entire file, loop through the file
    # and read it in chunks
    begin
      # seek to the appropriate position to read the next chunk, then
      # read it
      seek(idx)
      chunk = read(next_buffer_size)
      # count the number of lines in the chunk we just read and add that
      # chunk to the buffer; while we are at it, determine how many bytes
      # were just read and increment the total number of bytes read
      lines += chunk.count("\n")
      chunks.unshift chunk
      bytes_read += chunk.size
      # if there is more than a buffer prior to the chunk we just read, then
      # shift back by an entire buffer for the next read, otherwise just
      # move back to the start of the file and set the next_buffer_size
      # appropriately
      if idx > BUFFER_SIZE
        next_buffer_size = BUFFER_SIZE
        idx -= BUFFER_SIZE
      else
        next_buffer_size = idx
        idx = 0
      end
    end while lines < ( num_lines + 1 ) && bytes_read < size
    # now that we've got the number of lines we wanted (or have read the entire
    # file into our buffer), parse it and extract the last "num_lines" lines from it
    tail_of_file = chunks.join('')
    ary = tail_of_file.split(/\n/)
    lines_to_return = ary[-num_lines..-1]
  end

end

# and monkey patch the JSON class to add an is_json? method
module JSON
  def self.is_json?(foo)
    begin
      return false unless foo.is_a?(String)
      JSON.parse(foo).all?
    rescue JSON::ParserError
      false
    end
  end
end

# Root ProjectRazor namespace
# @author Nicholas Weaver
module ProjectRazor
  module Slice

    # ProjectRazor Slice System
    # Used for system management
    # @author Nicholas Weaver
    class Logviewer < ProjectRazor::Slice::Base

      # Initializes ProjectRazor::Slice::System including #slice_commands, #slice_commands_help, & #slice_name
      # @param [Array] args
      def initialize(args)

        super(args)
        @new_slice_style = true # switch to new slice style

        # define a couple of "help strings" (for the tail and filter commands)
        tail_help_str = "razor logviewer tail [NLINES] [filter EXPR]"
        filter_help_str = "razor logviewer filter EXPR [tail [NLINES]]"
        general_help_str = "razor logviewer [tail [NLINES]] [filter EXPR]"
        # Here we create a hash of the command string to the method it corresponds to for routing.
        @slice_commands = {:tail => { /^[0-9]+$/ => {:default => "tail_razor_log",
                                                     :filter => { /^{.*}$/ => "tail_then_filter_razor_log",
                                                                  :default => :help,
                                                                  :else => :help,
                                                                  :help => tail_help_str},
                                                     :else => :help,
                                                     :help => tail_help_str},
                                      :filter => { /^{.*}$/ => "tail_then_filter_razor_log",
                                                   :default => :help,
                                                   :else => :help,
                                                   :help => tail_help_str},
                                      :default => "tail_razor_log",
                                      :else => :help,
                                      :help => tail_help_str},
                           :filter => { /^{.*}$/ => {:tail => { /^[0-9]+$/ => "filter_then_tail_razor_log",
                                                                :else => :help,
                                                                :default => "filter_then_tail_razor_log",
                                                                :help => filter_help_str},
                                                     :default => "filter_razor_log",
                                                     :else => :help,
                                                     :help => filter_help_str},
                                        :default => :help,
                                        :else => :help,
                                        :help => filter_help_str},
                           :default => "view_razor_log",
                           :else => :help,
                           :help => general_help_str
        }
        @slice_name = "Logviewer"
        @logfile = File.join(get_logfile_path, "project_razor.log")
      end

      # uses the location of the Razor configuration file to determine the path to the
      # ${RAZOR_HOME}/log directory (which is where the logfiles for Razor are located)
      def get_logfile_path
        # split the path into an array using the File::SEPARATOR as the separator
        conf_dir_parts =  $config_server_path.split(File::SEPARATOR)
        # and extract all but the last two pieces (which will contain the configuration
        # directory name and the name of the configuration file)
        logfile_path_parts = conf_dir_parts[0...-2]
        # append the "log" directory name to the array, and join that array back together
        # using the File.join() method
        logfile_path_parts << "log"
        File.join(logfile_path_parts)
      end

      # Prints the contents from the current razor logfile to the command line
      def view_razor_log
        if @web_command
          # if it's a web command, return an error indicating that this method is not
          # yet implemented as a web command.  We'll probably have to work out a
          # separate mechanism for feeding this information back to the Node.js
          # instances as an ATOM feed of some sort
          slice_error("NotImplemented")
        else
          # else, just read the logfile and print the contents to the command line
          begin
            File.open(@logfile, 'r').each_chunk { |chunk|
              print chunk
            }
          rescue => e
            # if get to here, there was an issue reading the logfile, return the error
            logger.error e.message
            slice_error e.message
          end
        end
      end

      # Prints the tail of the current razor logfile to the command line
      def tail_razor_log
        if @web_command
          # if it's a web command, return an error indicating that this method is not
          # yet implemented as a web command.  We'll probably have to work out a
          # separate mechanism for feeding this information back to the Node.js
          # instances as an ATOM feed of some sort
          slice_error("NotImplemented")
        else
          # else, just read and print the tail of the logfile to the command line
          tail_of_file = []
          begin
            last_arg = @prev_args.look
            num_lines_tail = nil
            # if the last argument is an integer, us it as the number of lines
            if /[0-9]+/.match(last_arg)
              num_lines_tail = last_arg.to_i
            end
            tail_of_file = tail_of_file_as_array(num_lines_tail)
          rescue => e
            logger.error e.message
            slice_error e.message
          end
          tail_of_file.each { |line|
            puts line
          }
        end
      end

      # filters the current razor logfile, printing all matching lines
      def filter_razor_log
        if @web_command
          # if it's a web command, return an error indicating that this method is not
          # yet implemented as a web command.  We'll probably have to work out a
          # separate mechanism for feeding this information back to the Node.js
          # instances as an ATOM feed of some sort
          slice_error("NotImplemented")
        else
          begin
            filter_expr_string = @prev_args.look
            parseable, log_level_match, elapsed_time_str, class_name_match,
                method_name_match, log_message_match = get_filter_criteria(filter_expr_string)
            if parseable
              #puts "log_level_match = #{PP.pp(log_level_match, "")}"
              #puts "elapsed_time_str = #{PP.pp(elapsed_time_str, "")}"
              #puts "class_name_match = #{PP.pp(class_name_match, "")}"
              #puts "method_name_match = #{PP.pp(method_name_match, "")}"
              #puts "log_message_match = #{PP.pp(log_message_match, "")}"
              # initialize a few variables
              incomplete_last_line = false
              prev_line = ""
              # and loop through the file in chunks, parsing each chunk and filtering out
              # the lines that don't match the criteria parsed from the filter expresssion
              # passed into the command (above)
              File.open(@logfile, 'r').each_chunk { |chunk|
                line_array = []

                # split the chunk into a line array using the newline character as a delimiter
                line_array.concat(chunk.split("\n"))
                # if the last chunk had an incomplete last line, then add it to the start
                # of the first element of the line_array
                if incomplete_last_line
                  line_array[0] = prev_line + line_array[0]
                end

                # test to see if this chunk ends with a newline or not, if not then the last
                # line of this chunk is incomplete; will be important later on
                incomplete_last_line = (chunk.end_with?("\n") ? false : true)
                # initialize a few variables, then loop through all of the lines in this chunk
                filtered_chunk = ""
                nlines_chunk = chunk.count("\n"); count = 0
                line_array.each { |line|
                  if incomplete_last_line && count == nlines_chunk

                    # if the last line is incomplete and we've already read in all of the complete
                    # lines in the current chunk, then save this one as the 'prev_line' (will be)
                    # used outputting the next chunk
                    prev_line = line

                  else

                    # otherwise, grab add the line to the filtered_chunk if it matches and
                    # increment our counter
                    filtered_chunk << line + "\n" if line_matches_criteria(line, log_level_match, class_name_match,
                                                                           method_name_match, log_message_match)
                    count += 1

                  end
                }
                print filtered_chunk
              }
            else
              # if get here, it's an error (the string passed in wasn't a JSON string)
              logger.error "The filter expression '#{filter_expr_string}' is not a JSON string"
              slice_error "The filter expression '#{filter_expr_string}' is not a JSON string"
            end
          rescue => e
            # if get to here, there was an issue parsing the filter criteria or
            # reading the logfile, return that error
            logger.error e.message
            slice_error e.message
          end
        end
      end

      # tails the current razor logfile, then filters the result
      def tail_then_filter_razor_log
        if @web_command
          # if it's a web command, return an error indicating that this method is not
          # yet implemented as a web command.  We'll probably have to work out a
          # separate mechanism for feeding this information back to the Node.js
          # instances as an ATOM feed of some sort
          slice_error("NotImplemented")
        else
          # then, peek into the second element down in the stack of previous arguments
          # (which should be the number of lines to tail before filtering).  Note:  if no
          # NLINES argument was specified in the command, then the second element down in
          # the stack will actually be the string "tail" ()rather than the number of lines
          # to tail off of the file before filtering).  In that case, we ensure that the
          # num_lines_tail value is set to nil rather than attempting to convert the string
          # "tail" into an integer (all other error conditions should be handled in the
          # logic of the @slice_commands hash defined above)
          num_lines_tail_str = @prev_args.peek(2)
          num_lines_tail = (num_lines_tail_str == "tail" ? nil : num_lines_tail_str.to_i)
          # and grab the argument at the top of the prev_args stack (which should be the
          # filter expression)
          filter_expr_string = @prev_args.look
          @prev_args.push(filter_expr_string) if filter_expr_string
          parseable, log_level_match, elapsed_time_str, class_name_match,
              method_name_match, log_message_match = get_filter_criteria(filter_expr_string)
          if parseable
            puts "tail #{(num_lines_tail ? num_lines_tail : 10)} from the razor log, then apply a filter to the tail"
            puts "this method is not yet implemented..."
          else
            # if get here, it's an error (the string passed in wasn't a JSON string)
            logger.error "The filter expression '#{filter_expr_string}' is not a JSON string"
            slice_error "The filter expression '#{filter_expr_string}' is not a JSON string"
          end
        end
      end

      # filters the current razor logfile, then tails the result
      def filter_then_tail_razor_log
        if @web_command
          # if it's a web command, return an error indicating that this method is not
          # yet implemented as a web command.  We'll probably have to work out a
          # separate mechanism for feeding this information back to the Node.js
          # instances as an ATOM feed of some sort
          slice_error("NotImplemented")
        else
          # then, peek into the second element down in the stack of previous arguments
          # (which should be the expression to use as a filter on the log before tailing
          # the result).  Note:  if the second element down in the stack is the string
          # "filter", then no value was supplied for the "tail" part of this command.
          # In that case, we'll just use the first element down in the stack as the
          # filter_expr_string value instead.
          filter_expr_string = @prev_args.peek(2)
          filter_expr_string = @prev_args.peek(1) if filter_expr_string == "filter"
          # and grab the top argument from the stack of previous arguments (which should
          # be the number of lines to tail).  If the previous argument turns out to be
          # "tail" then no number of lines was included, so set the nlines_tail to nil and move on
          nlines_tail_str = @prev_args.look
          nlines_tail = (nlines_tail_str == "tail" ? nil : nlines_tail_str.to_i)
          # now, parse the filter_expr_string to get the parts (should be a JSON string with
          # key-value pairs where the values are regular expressions and the keys include one or more
          # of the following:  log_level, elapsed_time, class_name, or pattern)
          parseable, log_level_match, elapsed_time_str, class_name_match,
              method_name_match, log_message_match = get_filter_criteria(filter_expr_string)
          if parseable
            puts "filter razor log using the following criteria (then tail #{(nlines_tail ? nlines_tail : 10)} lines from the result):"
            puts "this method is not yet implemented..."
          else
            # if get here, it's an error (the string passed in wasn't a JSON string)
            logger.error "The filter expression '#{filter_expr_string}' is not a JSON string"
            slice_error "The filter expression '#{filter_expr_string}' is not a JSON string"
          end
        end
      end

      private
      # gets the tail of the current logfile as an array of strings
      def tail_of_file_as_array(num_lines_tail)
        tail_of_file = []
        File.open(@logfile) { |file|
          tail_of_file = file.tail(num_lines_tail)
        }
        tail_of_file
      end

      # parses the input filter_expr_string and returns an array of the various types
      # of filter criteria that could be included along with a flag indicating whether
      # or not the input filter_expr_string was a valid JSON string
      def get_filter_criteria(filter_expr_string)
        # now, parse the filter_expr_string to get the parts (should be a JSON string with
        # key-value pairs where the values are regular expressions and the keys include one or more
        # of the following:  log_level, elapsed_time, class_name, or pattern)
        log_level_match = elapsed_time_str = class_name_match = nil
        method_name_match = log_message_match = nil
        parseable = false
        if JSON.is_json?(filter_expr_string)
          parseable = true
          match_criteria = JSON.parse(filter_expr_string)
          match_criteria.each { |key, value|
            case key
              when "log_level"
                log_level_match = Regexp.new(value)
              when "elapsed_time"
                elapsed_time_str = value
              when "class_name"
                class_name_match = Regexp.new(value)
              when "method_name"
                method_name_match = Regexp.new(value)
              when "log_message"
                log_message_match = Regexp.new(value)
              else
                logger.warn "Unrecognized key in filter expression: '#{key}' (ignored); valid values" +
                                "are 'log_level', 'elapsed_time', 'class_name', or 'log_message'"
            end
          }
        end
        # return the results to the caller
        [parseable, log_level_match, elapsed_time_str, class_name_match, method_name_match, log_message_match]
      end

      # used to determine if a line matches the current filter criteria
      def line_matches_criteria(line_to_test, log_level_match, class_name_match,
          method_name_match, log_message)
        # this regular expression should parse out the timestamp for the
        # message, the log-level, the class-name, the method-name, and the
        # log-message itself into the first to fifth elements of the match_data
        # value returned by a log_line_regexp() call with the input line as
        # an argument to that call (the zero'th element will contain the entire
        # section of the line that matches if there is a match)
        log_line_regexp = /^[A-Z]\,\s+\[([^\s]+)\s+\#[0-9]+\]\s+([A-Z]+)\s+\-\-\s+([^\s\#]+)\#([^\:]+)\:\s+(.*)$/
        match_data = log_line_regexp.match(line_to_test)
        # if the match_data value is nil, then the parsing failed and there is no match
        # with this line, so return false
        return false unless match_data
        # check to see if the current line matches our criteria (if one of the criteria
        # is nil, anything is assumed to match that criteria)
        if (!log_level_match || log_level_match.match(match_data[2])) &&
            (!class_name_match || class_name_match.match(match_data[3])) &&
            (!method_name_match || method_name_match.match(match_data[4])) &&
            (!log_message || log_message.match(match_data[5]))
          return true
        end
        false
      end

      # used to determine if a line falls prior to a particular time
      def was_logged_before_time(line, cutoff_time)

      end

    end
  end
end
