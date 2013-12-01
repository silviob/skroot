
require 'webrick'
require 'thread'
require 'logger'

def main()
  $log = Logger.new STDERR
  $log.formatter = lambda do |sev, time, name, msg|
    timestring = time.strftime '[%Y-%m-%d %H:%M:%S]'
    "#{timestring} #{sev}  #{msg}\n"
  end
  $log.level = Logger::DEBUG
  $log.info "Skroot Server for #{ARGV[0]}"
  model = Model.new(ARGV[0])
  controller = Controller.new model
  server = Server.new :Port => 8000

  Thread.new do
    begin
      model.load
    rescue => e
      $log.fatal "Error while loading the model: #{e}"
      server.shutdown
    end
  end

  server.controller = controller
  trap 'INT' do server.shutdown end
  server.start
end


class Model

  attr_reader :filename, :procs, :files


  class FileEntry
    
    attr_accessor :filename, :parent, :id
    attr_reader :read_procs, :write_procs, :children

    def initialize()
      @write_procs = []
      @read_procs = []
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

    attr_accessor :pid, :parent,:start_time, :end_time, :work_dir, :id
    attr_reader  :read_files, :write_files, :argv, :env, :children, :env_queries

    def initialize()
      @write_files = []
      @read_files = []
      @argv = []
      @env = []
      @children = []
      @env_queries = []
    end

  end

  def initialize(filename)
    @read_bytes = 0
    @filename = filename
    @mutex = Mutex.new
    @procs = []
    @files = []
    @filemap = {}
    @procmap = {}
    @entry_expression = /^([0-9]+) ([0-9]+) (|[a-z]+): (.*)$/
  end

  def mtime()
    File.mtime(@filename)
  end

  def progress()
    return [ @read_bytes, File.stat(@filename).size ]
  end

  def load()
    $log.info "Loading file #{@filename}"
    File.open(@filename).each_line do |line|
      @mutex.synchronize do 
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
        end
      end
    end
  end

  def self.dependencies(object)
    deps = []
    q = [object]
    existing = {}
    while(q.size > 0)
      cur = q.shift
      if not existing[cur]
        existing[cur] = true
        deps.push cur
        if cur.respond_to? :read_files
          q += cur.read_files
        end
        if cur.respond_to? :write_procs
          q += cur.write_procs
        end
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
    end
    proc.start_time = time
  end

  def fork(proc, time, parent)
    proc.parent = proc_for_pid parent
    proc.parent.children << proc
  end

  def open(proc, time, fileinfo)
    exp = /^(.*) ([a|d|w|r|t|\+|b]+)$/
    match = exp.match fileinfo
    if not match
      loger.fatal "troubling fileinfo: #{fileinfo}"
    end
    filename = match[1]
    mode = match[2]
    file = file_for_filename filename
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
    proc.end_time = time
  end

  alias exit fini

end


class Controller

  def initialize(model)
    @model = model
    title = "Skroot -- #{@model.filename}"
    @rootview = RootView.new self, title
    @fileview = FileView.new self, title
    @filelistview = FileListView.new self, title
    @procview = ProcessView.new self, title
    @proclistview = ProcessListView.new self, title
    @routes = []
    register_routes [
      [ '^/?$', 'root',
          lambda { @model }, @rootview ],
      [ '^/files/?$', 'root_files',
          lambda { @model.files.select { |f| f.parent == nil} }, @filelistview ],
      [ '^/files/#{id}$', 'files',
          lambda { |id| @model.files[id] }, @fileview ],
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
      [ '^/processes/?$', 'root_processes',
          lambda { @model.procs.select { |p| p.parent == nil } }, @proclistview ],
      [ '^/processes/#{id}$', 'proc',
          lambda { |id| @model.procs[id] }, @procview ],
      [ '^/processes/#{id}/children/?$', 'proc_children',
          lambda { |id| @model.procs[id].children }, @proclistview ],
    ]  
  end

  def register_routes(routes)
    meta = class << self; self; end
    routes.each do |path, name, handler, view|
      get_sym = ('get_' + name).to_sym
      get_handler = lambda do |match, res|
        if match.length == 2
          id = Integer match[1]
          res.body = view.render(handler.call(id))
        else
          res.body = view.render(handler.call)
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
          @model.access_model { send get_sym, match, res }
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
    args = proc.argv.join ' '
    a(@controller.proc_url proc) { "#{args}" }
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
      a(@controller.proc_children_url proc) { "+" }
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
    a(url) { "#{url}" }
  end

  def file_readers_link(file)
    url = @controller.file_readers_url(file)
    a(url) { "#{url}" }
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

  def a(href)
    "<a href=\"#{href}\">" << yield << "</a>"
  end

  def h2(title)
    "<h2>#{title}</h2>"
  end

  def h3(title)
    "<h3>#{title}</h3>"
  end

  def dl(terms)
    t = '<di>'
    terms.each { |name, value| t << "<dt>#{name}</dt><dd>#{value}</dd>" }
    t << '</di>'
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
  
end


class FileListView < View
  
  def render(files)
    html do
      body do
        h2("Files") <<
        ul(files.collect { |f| file_tree_link(f) })
      end
    end
  end

end


class RootView < View

  def render(model)
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

  def render(file)
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


class ProcessListView < View
  
  def render(processes)
    html do
      body do
        h2("Processes") <<
        ul(processes.collect {|p| proc_children_link(p) << ' ' << proc_link(p) })
      end
    end
  end

end


class ProcessView < View
  
  def render(proc)
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