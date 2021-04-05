# frozen_string_literal: true

load 'vendor/bundle/bundler/setup.rb'
require 'archivesspace/client'
require 'logger'
require 'uri'

# - Setup connections (source and dest)
# - Verify source and destination repositories exist
# - Retrieve modified record ids from source (or all if recent_only: false)
# - Retrieve EAD XML from source for each id
# - Convert EAD XML to json in destination (jsonmodel-from-format)
# - Check records: if destination has record delete it (we cannot overlay)
# - POST json to destination batch import endpoint

# TODO: notifications for failures
$logger = Logger.new($stdout)

def migrator(event:, context:)
  since  = modified_since(event['recent_only']).to_s
  source = setup_client('source', event)
  destination = setup_client('destination', event)

  $logger.info "using modified since: #{since}"
  $logger.info "using source: #{source.config.base_uri}"
  $logger.info "using destination: #{destination.config.base_uri}"

  source.resources(query: { modified_since: since }).each do |resource|
    next unless resource['publish']

    four_part_id = resolve_id(resource)
    $logger.info "[source] procesing resource #{four_part_id}: #{resource['uri']}"
    record = retrieve_resource_description(source, uri_to_id(resource['uri']))
    next unless record

    json = convert_record(destination, record, four_part_id)
    next unless json

    remove_existing_record(destination, four_part_id)
    import_record(destination, json, four_part_id)
  end

  true # we're happy =)
end

private

def convert_record(destination, record, four_part_id)
  base_repo = destination.config.base_repo
  destination.config.base_repo = nil
  $logger.info "[destination] converting resource #{four_part_id} to importable json"
  response = destination.post('plugins/jsonmodel_from_format/resource/ead', record)
  unless response.result.success?
    if response.parsed['error'] == 'Sinatra::NotFound'
      raise '[destination] jsonmodel plugin is not installed'
    else
      raise "[destination] error converting resource #{four_part_id} to json"
    end
  end

  response.body
rescue StandardError => e
  $logger.error e.message
  nil
ensure
  destination.config.base_repo = base_repo
end

def fatal_error(message)
  $logger.error message
  raise message
end

def import_record(destination, record, four_part_id)
  $logger.info "[destination] importing resource #{four_part_id}: #{destination.config.base_uri}"
  destination.post('batch_imports', record)
rescue StandardError => e
  $logger.error e.message
  nil
end

def modified_since(recent_only)
  recent_only ? (DateTime.now - 1.0).to_time.utc.to_i : 0
end

def remove_existing_record(destination, four_part_id)
  response = destination.get('find_by_id/resources', { query: { 'identifier[]': four_part_id } })
  response.parsed['resources'].each do |ref|
    $logger.info "[destination] deleting resource #{four_part_id}: #{ref['ref']}"
    destination.delete File.join('resources', uri_to_id(ref['ref']))
  end
rescue StandardError => e
  $logger.error e.message
  nil
end

def resolve_id(resource)
  # JSON.generate [
  #   resource.fetch('id_0'),
  #   resource.fetch('id_1', nil),
  #   resource.fetch('id_2', nil),
  #   resource.fetch('id_3', nil)
  # ]
  # Note: the default importer smushes everything into id_0
  JSON.generate([(0..3).map { |i| resource.fetch("id_#{i}", nil) }.compact.join('.')])
end

def retrieve_resource_description(source, id)
  response = source.get(
    File.join('resource_descriptions', "#{id}.xml"),
    {
      query: {
        include_unpublished: false,
        include_daos: true,
        numbered_cs: true,
        print_pdf: false
      }
    }
  )
  Nokogiri::XML(response.body).to_xml
rescue StandardError => e
  $logger.error e.message
  nil
end

def setup_client(role, event)
  client = ArchivesSpace::Client.new(setup(role, event)).login
  repository = File.join('repositories', event["#{role}_repo_id"].to_s)
  fatal_error "[#{role}] invalid repository: #{repository}" unless verify_repository(client, repository)

  client.config.base_repo = repository
  client
end

def setup(role, event)
  ArchivesSpace::Configuration.new(
    {
      base_uri: event["#{role}_url"],
      username: event["#{role}_username"],
      password: event["#{role}_password"],
      page_size: 50,
      throttle: 0,
      verify_ssl: URI.parse(event["#{role}_url"]).scheme == 'https'
    }
  )
end

def uri_to_id(uri)
  uri.split('/').last
end

def verify_repository(client, repository)
  client.get(repository).result.success?
end
