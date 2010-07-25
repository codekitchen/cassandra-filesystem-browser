# Cassandra Filesystem Browser

This is a quick demo app for my presentation on Cassandra for URUG, July 2010.
Run `file_tree.rb my_username /Root/of/filesystem` to import your filesystem
into Cassandra. Then browse it with the display_tree.rb sinatra app.

Run the same file_tree.rb command again to walk through the filesystem and
update Cassandra with any changed files. This currently does not detect deletes.

## Cassandra 0.6 Schema

    <Keyspace Name="FileTree">
      <ColumnFamily Name="User" />
      <ColumnFamily Name="Directories" ColumnType="Super" CompareSubcolumnsWith="UTF8Type" />
      <ColumnFamily Name="Files" ColumnType="Super" CompareWith="LongType" />
      <ColumnFamily Name="FileNameSearch" CompareWith="UTF8Type" />
    
      <ReplicaPlacementStrategy>org.apache.cassandra.locator.RackUnawareStrategy</ReplicaPlacementStrategy>
    
      <ReplicationFactor>1</ReplicationFactor>
    
      <EndPointSnitch>org.apache.cassandra.locator.EndPointSnitch</EndPointSnitch>
    </Keyspace>

## Required Gems

- cassandra
- sinatra
- haml
