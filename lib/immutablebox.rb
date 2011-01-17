require 'rubygems'
require 'bencode'
require 'base32'
require 'cgi'
require 'digest/sha1'
require 'fileutils'
require 'zlib'

IB_DIR = '.ib'

class Torrent
  def self.str2hex(str)
    str.unpack('C*').map{|v|"%02x" % v}.join
  end

  class Info
    def initialize(info)
      @info = info
      @info_hash = Digest::SHA1.digest(BEncode.dump(info))
      @piece_length = info['piece length']
      @name = info['name']
      @files = info['files'] || [{
        'length' => info['length'], 'path' => [@name]
      }]
      pieces = info['pieces']
      @pieces = (pieces.size / 20).times.map{|i| pieces[i * 20, 20]}
    end

    attr :info
    attr :info_hash
    attr :files
    attr :piece_length
    attr :name
    attr :pieces

    def to_s
      "magnet:?xt=urn:btih:%s" % Base32.encode(@info_hash)
    end

    def inspect
      Torrent.str2hex(@info_hash)
    end
  end

  def initialize(filename)
    torrent = BEncode.load(File.read(filename))
    @announce = torrent['announce']
    @creation_date = torrent['creation date']
    @info = Info.new(torrent['info'])
  end

  attr :info
  attr :creation_date
  attr :announce

  def to_s
    "%s&tr=%s" % [@info.to_s, CGI.escape(@announce)]
  end

  def inspect
    @info.inspect
  end
end

def load_torrent(tname)
  modifiedfiles = []
  torrent = Torrent.new(tname)
  info = torrent.info
  pieces = info.pieces.clone
  piece_length = info.piece_length

  files = []
  piece = nil
  info.files.each do |file|
    file_size = file['length']
    fd = if file['path'][0] != IB_DIR
      filename = file['path'].join('/')
      files << filename
      if File.exist?(filename)
        File.open(filename, 'rb')
      else
        StringIO.new(' ' * file_size)
      end
    end
    begin
      loop do
        if fd
          if piece.nil?
            piece = fd.read(piece_length)
            unless piece
              files = []
              break
            end
          else
            piece += fd.read(piece_length - piece.size)
          end
        else
          unless piece
            files = []
            break
          end
          piece += "\000" * file_size
        end
        break if piece.size < piece_length
        piece_hash = Digest::SHA1.digest(piece)
        if pieces.shift == piece_hash # good piece
          yield(piece_hash, piece)
        else
          modifiedfiles += files
        end
        piece = nil
      end
    ensure
      fd.close if fd
    end
  end

  if piece
    piece_hash = Digest::SHA1.digest(piece)
    if pieces.shift == piece_hash # good piece
      yield(piece_hash, piece)
    else
      modifiedfiles += files
    end
  end
  modifiedfiles.uniq
end

def save_torrent(tname, storage, files)
  torrent = Torrent.new(tname)
  info = torrent.info
  pieces = info.pieces.clone
  piece_length = info.piece_length
  info.files.each do |file|
    file_size = file['length']
    filename = file['path'].join('/')
    if file['path'][0] != IB_DIR and files.include?(filename)
      File.open(filename, 'wb') do |fd|
        n = file_size / piece_length
        mod = file_size % piece_length
        n.times do |i|
          piece_hash = pieces.shift
          piece = storage.get(piece_hash)
          fd.write(piece)
        end
        if mod > 0
          piece_hash = pieces.shift
          piece = storage.get(piece_hash)
          fd.write(piece[0, mod])
        end
      end
    else
      piece_hash = pieces.shift(file_size / piece_length)
    end
  end
end

def walk(path, &block)
  Dir.entries(path).select{|d| !(/\A\.+\z/.match d)}.each do |e|
    file = File.join(path, e)
    if File.directory?(file)
      walk(file, &block)
    else
      yield file
    end
  end
end

def split_path(path)
  d = path
  rv = []
  loop do
    d, f = File.split(d)
    rv.insert(0, f)
    break if d == '.'
  end
  rv
end

TORRENT_PIECE_SIZE = 2 ** 18

def make_torrent(name, path, tracker, priv, gap = false)
  torrent_pieces = []
  piece = ''
  gapn = 0
  files = []
  walk(path) do |file|
    next if file.index("./#{IB_DIR}/") == 0
    fileinfo = { 'path' => split_path(file) }
    files << fileinfo
    filesize = 0
    File.open(file, 'rb') do |fd|
      loop do
        data = fd.read(TORRENT_PIECE_SIZE - piece.size)
        break if data.nil?
        piece << data
        if piece.size == TORRENT_PIECE_SIZE
          torrent_pieces << Digest::SHA1.digest(piece)
          filesize += piece.size
          piece = ''
        end
      end
    end
    if piece.size > 0
      filesize += piece.size
      fileinfo['length'] = filesize
      gapsize = TORRENT_PIECE_SIZE - piece.size
      gapfile = "#{IB_DIR}/gap/#{gapn}"
      gapimage = "\000" * gapsize
      fileinfo = { 'length' => gapsize, 'path' => gapfile.split('/') }
      files << fileinfo
      gapn += 1
      piece << gapimage
      torrent_pieces << Digest::SHA1.digest(piece)
      piece = ''
      if gap
        File.open(gapfile, 'wb'){|fd| fd.write(gapimage)}
      end
    else
      fileinfo['length'] = filesize
    end
  end

  torrent = {
    'announce' => tracker,
    'created by' => 'statictorrent 0.0.0',
    'creation date' => Time.now.to_i,
    'info' => {
      'length' => TORRENT_PIECE_SIZE * torrent_pieces.size,
      'name' => name,
      'private' => priv ? 1 : 0,
      'pieces' => torrent_pieces.join,
      'piece length' => TORRENT_PIECE_SIZE,
      'files' => files,
    }
  }
  BEncode.dump(torrent)
end

class Storage
  def open
  end
  def close
  end
  def put
  end
  def get
  end
end

class LocalStorage < Storage
  def initialize(dir)
    @dir = dir
  end
  def open
    FileUtils.mkdir_p(@dir)
  end
  def compress?(piece)
    limit = 3 * TORRENT_PIECE_SIZE / 256
    [' ', "\n", "\000"].map{|c| piece.count(c)}.max < limit
  end
  def getfilename(piece_hash)
    "#{@dir}/#{Torrent.str2hex(piece_hash)}"
  end
  def put(piece_hash, piece)
    filename = getfilename(piece_hash)
    return if File.exist?(filename)
    File.open(filename, 'wb') do |fd|
      fd.write(compress?(piece) ? piece : Zlib::Deflate.deflate(piece))
    end
  end
  def get(piece_hash)
    filename = getfilename(piece_hash)
    return unless File.exist?(filename)
    piece = File.open(filename, 'rb'){|fd| fd.read}
    if piece.size == TORRENT_PIECE_SIZE
      piece
    else
      Zlib::Inflate.inflate(piece)
    end
  end
end

class DistributedStorage < Storage
  def initialize
    @storages = []
  end
  def <<(storage)
    @storages << storage
    self
  end
  def open
    @storages.each(&:open)
  end
  def close
    @storages.each(&:close)
  end
  def put(piece_hash, piece)
    dice = piece_hash.unpack('L').first % @storages.size
    @storages[dice].put(piece_hash, piece)
  end
end
