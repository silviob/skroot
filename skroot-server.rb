
require 'webrick'
require 'thread'
require 'logger'
require 'tsort'

def main()
  $log = Logger.new STDERR
  $log.formatter = lambda do |sev, time, name, msg|
    timestring = time.strftime '[%Y-%m-%d %H:%M:%S]'
    "#{timestring} #{sev}  #{msg}\n"
  end
  $log.level = Logger::DEBUG
  $log.info "Skroot Server for #{ARGV[0]}"
  model = Model.new(ARGV[0])
  count = 0
#  model.load
#  exit
  controller = Controller.new model
  server = Server.new :Port => 8000

  Thread.new do
    begin
      model.load
    rescue => e
      $log.fatal "Error while loading the model: #{e}"
      $log.fatal e.backtrace
      server.shutdown
    end
  end

  server.controller = controller
  trap 'INT' do server.shutdown end
  server.start
end


class Model

  attr_reader :filename, :procs, :files, :process_time


  class FileEntry
    
    attr_accessor :filename, :read_bytes, :write_bytes, :parent, :id
    attr_reader :read_procs, :write_procs, :children

    def initialize()
      @read_procs = []
      @write_procs = []
      @read_bytes = 0
      @write_bytes = 0
      @children = []
    end

    def file_dependencies()
      return Model.dependencies(self).select { |e| e.respond_to? :write_procs }
    end

    def proc_dependencies()
      return Model.dependencies(self).select { |e| e.respond_to? :read_files }
    end

  end


  class ProcEntry

    attr_accessor :pid, :parent,:start_time, :end_time, :work_dir, :id, :duration, :piped, :fds
    attr_reader  :read_files, :write_files, :argv, :env, :children, :env_queries

    def initialize()
      @write_files = []
      @read_files = []
      @argv = []
      @env = []
      @children = []
      @env_queries = []
      @duration = 0
      @piped = false
      @fds = {}
    end

  end

  def initialize(filename)
    @read_bytes = 0
    @process_time = 0
    @filename = filename
    @mutex = Mutex.new
    @procs = []
    @files = []
    @filemap = {}
    @procmap = {}
    @entry_expression = /^([0-9]+) ([0-9]+) (|[a-z]+): (.*)$/
    @partial_entry_expression = /^.*\\$/
  end

  def mtime()
    File.mtime(@filename)
  end

  def progress()
    return [ @read_bytes, File.stat(@filename).size ]
  end

  def load2()
    load_in_c do |contents|
      while contents.size > 0
          pid = contents.shift
          time = contents.shift
          type = contents.shift
          args = contents.shift
          begin
            if respond_to? type
              send type, proc_for_pid(pid), time, args
            else
              $log.warn "log type '#{type}' not supported"
            end
          rescue => e
            $log.warn "#{e}: #{pid} -- #{time} -- #{type} -- #{args}"
            raise
          end
      end
    end
  end

  def load()
    $log.info "Loading file #{@filename}"
    partial = ''
    File.open(@filename).each_line do |line|
      is_partial = line.match @partial_entry_expression
      if is_partial
        partial += line
        $log.warn "found partiale: #{line}"
        next
      end
      if partial.size > 0 and not is_partial
        line = partial + line
        partial = ''
        $log.warn "issuing partial entry #{line}"
      end
      @mutex.synchronize do
        start = Time.now
        @read_bytes += line.size # Assuming ASCII content
        match = line.match @entry_expression
        if match
          pid = match[1]
          proc = proc_for_pid pid
          time = match[2]
          type = match[3].to_sym
          args = match[4]
          if respond_to? type
            send type, proc, time, args
          else
            $log.warn "log type '#{type}' not supported"
          end
        else
          $log.warn "line: #{line} didnt match"
        end
        finish = Time.now
        @process_time += finish - start
      end
    end
  end

  def self.dependencies(object)
    deps = []
    q = [object]
    existing = {}
    while(q.size > 0)
      cur = q.pop
      if not existing.key? cur
        existing[cur] = :discovered
        q.push cur
        if cur.respond_to? :read_files
          q.push *cur.read_files
        end
        if cur.respond_to? :write_procs
          q.push *cur.write_procs
        end
      elsif existing[cur] == :discovered
        existing[cur] = :processed
        deps.push cur
      end
    end
    return deps
  end

  def access_model(&block)
    @mutex.synchronize {
      block.call()
    }
  end

  def proc_for_pid(pid)
    if not @procmap.has_key? pid
      proc = ProcEntry.new
      proc.pid = pid
      @procmap[pid] = proc
      id = @procs.size
      @procs << proc
      proc.id = id
    end
    return @procmap[pid]
  end

  def file_for_filename(filename)
    if filename == '.' or filename == '/'
      return nil
    end
    if not @filemap.has_key? filename
      file = FileEntry.new
      file.filename = filename
      updir, name = File.split filename
      file.parent = file_for_filename updir
      file.parent and file.parent.children << file
      @filemap[filename] = file
      id = @files.size
      @files << file
      file.id = id
    end
    return @filemap[filename]
  end

  def init(proc, time, not_used)
  end

  def start(proc, time, parent)
    if not proc.parent
      proc.parent = proc_for_pid parent
      proc.parent.children << proc
    end
    proc.start_time = Integer(time)
  end

  def fork(proc, time, parent)
    proc.parent = proc_for_pid parent
    proc.parent.children << proc
    proc.start_time = Integer(time)
  end

  def open(proc, time, fileinfo)
    exp = /^(.*) (\d+) ([a|m|e|d|w|r|t|\+|b]+)$/
    match = exp.match fileinfo
    if not match
      $log.fatal "troubling fileinfo: #{fileinfo}"
    end
    filename = match[1]
    fd = match[2]
    mode = match[3]
    file = file_for_filename filename
    if proc.parent and proc.parent.piped
      proc = proc.parent
    end
    proc.fds[Integer(fd)] = file
    if (mode.split(//) & ['+', 'w', 'a']).length > 0
      proc.write_files << file
      file.write_procs << proc
    end
    if (mode.split(//) & ['+', 'r']).length > 0
      proc.read_files << file
      file.read_procs << proc
    end
  end

  def miss(proc, time, arg)
  end

  def argv(proc, time, argv)
    proc.argv << argv
    if argv == '-pipe'
      proc.piped = true
    end
  end

  def env(proc, time, env)
    proc.env << env
  end

  def getenv(proc, time, env)
    proc.env_queries << env
  end

  def forking(proc, time, env)
  end

  def cwd(proc, time, dir)
    proc.work_dir = dir
  end

  def fini(proc, time, not_used)
    proc.end_time = Integer(time)
    begin
      proc.duration = proc.end_time - proc.start_time 
    rescue => e
      $log.warn "bad duration #{proc.start_time}:#{proc.start_time}"
    end
  end

  def close(proc, time, closeinfo)
    exp = /([0-9]+) (-?[0-9]+) (-?[0-9]+)/
    match = exp.match closeinfo
    if match
      fd = match[1]
      read = match[2]
      written = match[3]
      if proc.parent and proc.parent.piped
        proc = proc.parent
      end
      file = proc.fds[Integer(fd)]
      if file == nil then return end
      file.read_bytes += Integer(read)
      file.write_bytes += Integer(written)
    else
      $log.warn "closeinfo didn't match: #{closeinfo}"
    end
  end

  alias exit fini
  alias closef close

end


class Controller

  def initialize(model)
    @model = model
    title = "Skroot -- #{@model.filename}"
    @rootview = RootView.new self, title
    @fileview = FileView.new self, title
    @filelistview = FileListView.new self, title

    @allfilesview = AllFilesView.new self, title
    @proclistview = ProcessListView.new self, title

    @procview = ProcessView.new self, title
    @procscriptview = ProcessScriptView.new self, title
    @routes = []
    register_routes [
      [ '^/?$', 'root',
          lambda { || @model }, @rootview ],
      [ '^/files/?$', 'root_files',
          lambda { || @model.files.select { |f| f.parent == nil} }, @filelistview ],
      [ '^/files/#{id}$', 'files',
          lambda { |id| @model.files[id] }, @fileview ],
      [ '^/all_files/?$', 'all_files',
          lambda { || @model.files }, @allfilesview ],
      [ '^/files/#{id}/children/?$', 'file_children',
          lambda { |id| @model.files[id].children }, @filelistview ],
      [ '^/files/#{id}/writers/?$', 'file_writers',
          lambda { |id| @model.files[id].write_procs }, @proclistview ],
      [ '^/files/#{id}/readers/?$', 'file_readers',
          lambda { |id| @model.files[id].read_procs }, @proclistview ],
      [ '^/files/#{id}/file_dependencies/?$', 'file_dependencies',
          lambda { |id| @model.files[id].file_dependencies }, @filelistview ],
      [ '^/files/#{id}/proc_dependencies/?$', 'proc_dependencies',
          lambda { |id| @model.files[id].proc_dependencies }, @proclistview ],
      [ '^/files/#{id}/proc_dependencies_script/?$', 'proc_dependencies_script',
          lambda { |id| @model.files[id].proc_dependencies }, @procscriptview ],
      [ '^/processes/?$', 'root_processes',
          lambda { || @model.procs.select { |p| p.parent == nil } }, @proclistview ],
      [ '^/processes/#{id}$', 'proc',
          lambda { |id| @model.procs[id] }, @procview ],
      [ '^/processes/#{id}/children/?$', 'proc_children',
          lambda do |id| 
            children = @model.procs[id].children.sort_by do |p| 
              if p.duration
                p.duration
              else
                0
              end
            end
            children.reverse
          end, @proclistview ],
    ]  
  end

  def register_routes(routes)
    meta = class << self; self; end
    routes.each do |path, name, handler, view|
      get_sym = ('get_' + name).to_sym
      get_handler = lambda do |match, req, res|
        wants_id = match.size > 1
        if handler.arity == 0
          res.body = view.render(handler.call, req)
        elsif handler.arity == 1
          if wants_id
            id = Integer match[1]
            res.body = view.render(handler.call(id), req)
          else
            res.body = view.render(handler.call(req), req)
          end
        elsif handler.arity == 2
          id = Integer match[1]
          res.body = view.render(handler.call(id, req), req)
        else
          $log.warn "error dealing with #{req.path} arity:#{handler.arity}"
        end
      end
      meta.send(:define_method, get_sym, get_handler)
      @routes.push [ Regexp.new(path.gsub('#{id}', '([0-9]+)')), get_sym ]
      meta.send(:define_method, (name + '_url').to_sym, lambda do |o| 
        path.gsub('#{id}', o.id.to_s).gsub(/\$|\?|\^/, '')
      end)
    end
  end

  def get_instance(server, *options)
    self
  end

  def service(req, res)
    @routes.each do |test, get_sym|
      match = test.match(req.path)
      if match
        if respond_to? get_sym
          @model.access_model { send get_sym, match, req, res }
        else
          logger.warn "#{handler} not supported"
        end
        break
      end
    end
  end

end


class View

  def initialize(controller, title)
    @controller = controller
    @title = title
  end

  def processes_link()
    a(@controller.root_processes_url) { "#{@controller.root_processes_url}" }
  end

  def files_link()
    a(@controller.root_files_url) { "#{@controller.root_files_url}" }
  end

  def proc_short_link(proc)
    a(@controller.proc_url proc) { "#{proc.pid}:#{proc.argv[0]}" }
  end

  def proc_link(proc)
    cmdline = proc.argv.join ' '
    shortcmd = cmdline
    max = 120
    if cmdline.size > max
        shortcmd = cmdline[0..max] + '...'
    end
    a((@controller.proc_url proc), cmdline) { "#{shortcmd}" }
  end

  def file_link(file)
    a(@controller.files_url file) { "#{file.filename}"}
  end

  def file_tree_link(file)
    if file.children.size > 0
      a(@controller.file_children_url file) { file.filename }
    else
      file_link file
    end
  end

  def proc_children_link(proc)
    if proc.children.size > 0
      a(@controller.proc_children_url proc) { "+ (#{proc.children.size})" }
    else
      ''
    end
  end

  def file_file_dependencies_link(file)
    url = @controller.file_dependencies_url(file)
    a(url) { "#{url}" }
  end

  def file_proc_dependencies_link(file)
    url = @controller.proc_dependencies_url(file)
    a(url) { "#{url}" }
  end

  def file_writers_link(file)
    url = @controller.file_writers_url(file)
    a(url) { "#{file.write_procs.size}" }
  end

  def file_readers_link(file)
    url = @controller.file_readers_url(file)
    a(url) { "#{file.read_procs.size}" }
  end

  def html()
    "<html><head><title>#{@title}</title>" <<
    '<link href="//netdna.bootstrapcdn.com/' <<
    'bootstrap/3.0.2/css/bootstrap.min.css"' <<
    ' rel="stylesheet"></head>' <<
     yield << '</html>'
  end

  def body()
    '<body class="container">' << yield << '</body>'
  end

  def a(href, title='')
    "<a href=\"#{href}\" title=\"#{title}\">" << yield << "</a>"
  end

  def h2(title)
    "<h2>#{title}</h2>"
  end

  def h3(title)
    "<h3>#{title}</h3>"
  end

  def dl(terms)
    t = '<dl class="dl-horizontal">'
    terms.each { |name, value| t << "<dt>#{name}</dt><dd>#{value}</dd>" }
    t << '</dl>'
    return t
  end

  def li(item)
    "<li>#{item}</li>"
  end

  def ol(list)
    t = '<ol>'
    list.each { |i| t << li(i) }
    t << '</ol>'
  end

  def ul(list)
    t = '<ul>'
    list.each { |i| t << li(i) }
    t << '</ul>'
  end

  def th(header)
    "<th>#{header}</th>"
  end

  def td(data)
    "<td>#{data}</td>"
  end

  def tr(row)
    "<tr>#{row}</tr>"
  end

  def table(headers, content)
    t = '<table class="table table-hover table-striped"><thead>'
    t << tr(headers.collect { |h| th h })
    t << '</thead><tbody>'
    content.each do |row|
      t << tr(row.collect { |d| td d })
    end
    t << '</tbody></table>'
  end
  
end


class FileListView < View

  def initialize(controller, title)
    super controller, title
    @filelistview = ObjectListView.new controller, title
    @filelistview.title = 'Files'
    @filelistview.column_headers = [ 'Filename', 'Readers', 'Bytes Read',
                                                 'Writers', 'Bytes Written' ]
    @filelistview.columns = [ lambda { |f,v| v.file_link(f) },
                              lambda { |f,v| v.file_readers_link(f) },
                              lambda { |f,v| f.read_bytes },
                              lambda { |f,v| v.file_writers_link(f) },
                              lambda { |f,v| f.write_bytes } ]
    @filelistview.sorters = [ lambda { |f| f.filename },
                              lambda { |f| f.read_procs.size },
                              lambda { |f| f.read_bytes },
                              lambda { |f| f.write_procs.size },
                              lambda { |f| f.write_bytes } ]
  end
  
  def render(files, req)
    dirs = files.select { |f| f.children.size > 0 }
    leafs = files.select { |f| f.children.size == 0 }
    html do
      body do
        rendered = ''
        if dirs.size > 0
          rendered << h2("Directories") <<
                   ul(dirs.collect { |d| file_tree_link(d) })
        end
        if leafs.size > 0
          rendered << @filelistview.render(leafs, req)
        end
        rendered
      end
    end
  end

end


class RootView < View

  def render(model, req)
    loaded, size = model.progress
    mtime = model.mtime
    html do
      body do
        h2('Skroot') <<
        h3(model.filename) <<
        dl([
          ['Log File', model.filename],
          ['Last Modified', model.mtime],
          ['Size', size],
          ['Bytes Loaded', loaded],
          ['Progress', loaded / (size + 0.0)],
          ['Process Time', model.process_time],
          ['Bytes per Second', loaded / (model.process_time + 0.0)],
          ['Files Tracked', model.files.length],
          ['Processes Tracked', model.procs.length],
          ['Root Processes', processes_link],
          ['Root Files', files_link]
        ])
      end
    end
  end

end


class FileView < View

  def render(file, req)
    parent_link = if file.parent
      file_link file.parent
    else
      'no parent'
    end
    html do
      body do
        h2(file.filename) << 
        dl([
          ['Parent', parent_link],
          ['File Dependencies', file_file_dependencies_link(file)],
          ['Process Dependencies', file_proc_dependencies_link(file)],
          ['Writers', file_writers_link(file)],
          ['Readers', file_readers_link(file)]
        ])
      end
    end
  end

end


class AllFilesView < View

  def initialize(controller, title)
    @allfilesview = ObjectListView.new self, title
    @allfilesview.title = 'All Files and Dependents'
    @allfilesview.column_headers = ['Dependents', 'Path']
    @allfilesview.columns = [ lambda { |f,v| f.read_procs.size },
                              lambda { |f,v| v.file_link(f) } ]
    @allfilesview.sorters = [ lambda { |f| f.read_procs.size },
                              lambda { |f| f.filename } ]
  end

  def render(files, req)
    html do
      body do
        @allfilesview.render(files, req)
      end
    end
  end

end


class ProcessListView < View

  def initialize(controller, title)
    super controller, title
    @proclistview = ObjectListView.new controller, title
    @proclistview.title = 'Processes'
    @proclistview.column_headers = ['PID', 'Command', 'Duration', 'Children']
    @proclistview.columns = [ lambda { |p,v| p.pid },
                              lambda { |p,v| v.proc_link(p) },
                              lambda { |p,v| p.duration },
                              lambda { |p,v| v.proc_children_link(p) } ]
    @proclistview.sorters = [ lambda { |p| p.pid },
                              lambda { |p| p.argv.join ' ' },
                              lambda { |p| p.duration },
                              lambda { |p| p.children.size } ]
  end

  def render(processes, req)
    html do
      body do
        @proclistview.render(processes, req)
      end
    end
  end

end

class ObjectListView < View

  attr_accessor :sorters, :columns, :column_headers, :title

  def render(objects, req)
    query = req.query
    order = 0
    ascending = true
    if query.has_key? 'sort'
      order = Integer(query['sort'])
    end
    if query.has_key? 'ascending'
      ascending = Integer(query['ascending']) == 1
    end
    sorter = @sorters[order]
    if ascending
      objects = objects.sort { |a,b| sorter.call(a) <=> sorter.call(b) }
    else
      objects = objects.sort { |a,b| sorter.call(b) <=> sorter.call(a) }
    end
    path = req.path
    i = -1
    headers = column_headers.collect do |h|
      i += 1
      query_ascending = 1
      if order == i
        if ascending
          query_ascending = 0
        else
          query_ascending = 1
        end
      end
      a(path + "?sort=#{i}&ascending=#{query_ascending}") { h }
    end
    content = objects.collect do |o|
      rowdata = []
      if columns 
        columns.each do |func|
          rowdata << func.call(o, self)
        end
      end
      rowdata
    end
    h2(title) <<
    table(headers, content)
  end

end

class ProcessScriptView < View
  
  attr_accessor :columns, :column_headers

  def render(processes, req)
    t = ''
    processes.each do |p|
      t << "cd #{p.work_dir}\n"
      p.env.each do |e|
        t << "export '#{e}'\n"
      end
      t << p.argv.select { |a| a[0..4] != '-spec' } .join(' ') << "\n"
    end
    t
  end

end


class ProcessView < View
  
  def render(proc, req)
    parent_link = if proc.parent
      proc_short_link proc.parent
    else
      'no parent'
    end
    html do
      body do
        h2("Process #{proc.pid}") <<
        h3('Stats') <<
        dl([
          ['Parent', parent_link ],
          ['Duration', proc.duration],
          ['Start Time', proc.start_time],
          ['End Time', proc.end_time],
          ['Working Directory', proc.work_dir],
          ['Arguments', proc.argv.join(' ')]
        ]) <<
        h3('Input Files') <<
        ol(proc.read_files.collect {|f| file_link f }) <<
        h3('Output Files') <<
        ol(proc.write_files.collect {|f| file_link f }) <<
        h3('Environment') <<
        ul(proc.env)
      end
    end
  end

end


class Server < WEBrick::HTTPServer

  attr_accessor :controller

  def search_servlet(path)
    return controller
  end

end

main