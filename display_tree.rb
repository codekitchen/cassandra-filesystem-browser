#!/usr/bin/env ruby

# A simple sinatra app for browsing the file structures inserted into Cassandra
# using `file_tree.rb username /Root/Directory`

require 'rubygems'
require 'sinatra'
require 'cassandra'
require 'haml'
include SimpleUUID

$cassandra = Cassandra.new('FileTree', 'cassandra-1:9160')

get '/tree/:username/*' do
  @username = params[:username]
  @path = params[:splat].first
  key = "#{@username}:#{@path}"

  # retrieve one more result than we will display, so we know if there's a next
  # page, and if so, what column name it starts at.
  #
  # cassandra doesn't currently support starting at a column numeric index, only
  # a column name, so we support walking backwards by reversing the query
  # results when necessary.
  count = 26
  @start = params[:start]
  reverse = !!params[:rev]

  @entries = $cassandra.get(:Directories, key,
                            :start => @start, :count => count,
                            :reversed => reverse).to_a

  if reverse
    @entries.reverse!
    if @entries.size == count
      @start = nil
    else
      @start = @entries.first.first
    end
  end

  if @entries.size == count
    @next = @entries.last.first
    @entries.delete_at(@entries.length - 1)
  end

  haml :tree
end

get '/file/:username/*' do
  @username = params[:username]
  @path = params[:splat].first
  key = "#{@username}:#{@path}"

  @versions = $cassandra.get(:Files, key)

  haml :file
end

get '/search/:username' do
  @username = params[:username]
  @search = params[:q]
  key = "#{@username}:#{@search}"

  @found = $cassandra.get(:FileNameSearch, key).keys
  @results = $cassandra.multi_get(:Files, @found,
                                  :reversed => true, :count => 1)

  haml :search
end

# show the list of live servers known to this web app. the current ruby
# cassandra gem doesn't seem to handle servers becoming unresponsive very
# gracefully at all. it also seems to make requests against servers that are
# still bootstrapping, resulting in empty responses.
get '/utils/servers' do
  $cassandra.servers.join("\n")
end

def link_to_parent(username, splats)
  File.join("/tree", username, splats.split("/")[0..-2])
end

def link_to_tree(username, path, name)
  File.join("/tree", username, path, name[2..-1])
end

def link_to_file(username, path, name)
  File.join("/file", username, path, name[2..-1])
end

def link_to_search_result(username, fullpath)
  File.join("/file", username, fullpath)
end

def display_name(filename)
  # strip off the 0: / 1: prefix
  filename[2..-1]
end
