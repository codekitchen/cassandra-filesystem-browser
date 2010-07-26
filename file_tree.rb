#!/usr/bin/env ruby

require 'rubygems'
require 'cassandra'
require 'openssl'

$cassandra = Cassandra.new('FileTree', 'cassandra-1:9160')

user = ARGV[0]
# directory to treat as the 'root' of the virtual filesystem
dir  = Dir.new(ARGV[1])

# This schema is optimized for the file browser web app, not necessarily for
# inserting new files and new versions of files. Insertion is fairly quick as
# well, but needs work.
#
# By choosing cassandra's random partitioner, we spread a user's files and
# directories randomly across all the nodes in the cassandra cluster. This helps
# eliminate hotspots that could be caused by heavy users of the app. Really, a
# production system would probably cache the recently accessed files and
# directories in memcache (and tweak cassandra's caching parameters
# appropriately, too).
#
# There are two main ColumnFamilies in this app, both SuperColumnFamilies:
#
# Directories is a materialized view on the contents of each directory at this
# point in time. This allows the web UI to render the entire directory view with
# one call to cassandra:
#   dir_name => { child_name => child_info }
#
# child_info is a cached view on the latest version of the file. So you can pull
# the size, mtime, etc., of the latest version as part of the get(:Directory,
# ...) call, but for more details you'll need to get(:File, ...)
#
# e.g., in JSON:
#
# Directories =
#   { "bpalmer:/Users/bpalmer":
#     { "1:.vimrc":
#         { type: 'file', size: 1234, mtime: 12345678 },
#       "0:Documents":
#         { type: 'directory' },
#     },
# =>  "/Users/bpalmer/Documents":
#     { ...
#     }
#   };
#
#
# And Files:
#   file_name => { version_id => version_info }
#
# version_id is the unique identifier for this version of the file. In this
# system, rather than a UUID, we use the timestamp when the file version was
# added to cassandra.
#
# JSON:
#
# Files =
#   { "bpalmer:/Users/bpalmer/.vimrc":
#     { 1234:
#         { size: 5678, mtime: 12345678, sha1: "abcd..." },
#       1235:
#         { ... }
#     }
#   };
#
# There's also a simple "full-text search" functionality, which doesn't do
# stemming or anything, just matches whole tokens. The filename is split into
# words, and each word is indexed. Note this is a normal ColumnFamily, not a
# super column family.
#
# FileNameSearch =
#   { "bpalmer:salsa":
#       { "/Users/bpalmer/Recipes/salsa.txt": '', "another salsa": '' },
#     "bpalmer:pdf":
#       { "/Path/to/some.pdf": '' }
#   };

def insert_all(user, dir, root)
  puts "scanning (#{dir.path})"

  children = dir.entries - ['.', '..', '.DS_Store', "Icon\r"]
  # the key under the Directories ColumnFamily
  dir_key = "#{user}:#{dir.path[root.length+1 .. -1]}"

  children.each do |child|
    fullpath = File.join(dir.path, child)

    if File.directory?(fullpath)
      # we append "0:" to directories and "1:" to files, so that the directories
      # always come before the files in sorted order.
      # this is very, very UI-dependent, but making these decisions up-front can
      # have a big impact on your application performance down the road. for
      # instance, sorting directories in front of files without this would
      # involve reading in the entire directory, even when the request is just
      # for a slice, since we need to do the sort application-side.
      child_key = "0:"+child
      info = {'type' => 'directory'}
      $cassandra.insert(:Directories, dir_key, { child_key => info })

      insert_all(user, Dir.new(fullpath), root)
    else
      # see comment above about prefixing
      child_key = "1:"+child
      # the fullpath of the file relative to the root of the virtual filesystem
      relative = fullpath[root.length+1 .. -1]
      key = "#{user}:#{relative}"
      # this returns { timestamp => { .. file details incl. sha1 .. } }
      prev_info = $cassandra.get(:Files, key, :count => 1, :reversed => true)
      # we really just want the values
      prev_info && prev_info = prev_info.values.first

      sha1 = OpenSSL::Digest::SHA1.hexdigest(File.read(fullpath))
      if prev_info && sha1 == prev_info['sha1']
        # puts "file hasn't changed (#{key})"
        next
      end

      stime = Time.now.to_i
      details = {}
      # the key in the super column is the time this version was added to
      # cassandra. this gives us sorting on version timestamp for free.
      super_column = { stime => details }

      stat = File.stat(fullpath)
      cached_info = {}
      cached_info['size'] = details['size'] = stat.size
      cached_info['mtime'] = details['mtime'] = stat.mtime.to_i.to_s
      details['stime'] = stime
      details['sha1'] = sha1

      puts "inserting file (#{key})"
      # add this new version to the Files column family. if the file has no
      # versions already, this automatically adds the file. otherwise, it
      # appends another set of columns to the existing supercolumn.
      $cassandra.insert(:Files, key, super_column)
      # also append to the directory. this creates the directory entry if it
      # doesn't exist, and replaces the previous file info if an earlier version
      # of the file already exists in the Directory entry.
      $cassandra.insert(:Directories, dir_key, { child_key => cached_info })

      # search considers the filename only, not the parent directory names
      add_to_fts(user, child, relative)
    end
  end
end

# for files only. no FTS on directories supported.
def add_to_fts(user, fname, fullpath)
  # simplistic full text search word splitting. no stemming is supported.
  words = fname.split(%r{[\.\s]+}).map { |w| w.downcase }
  $cassandra.batch do
    words.each do |word|
      key = "#{user}:#{word}"
      $cassandra.insert(:FileNameSearch, key, { fullpath => '' })
    end
  end
end

insert_all(user, dir, dir.path)
