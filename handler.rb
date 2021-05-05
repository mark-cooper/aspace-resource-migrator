# frozen_string_literal: true

load 'vendor/bundle/bundler/setup.rb'
require 'archivesspace/client'
require 'logger'

# - Setup connections (source and dest)
# - Verify source and destination repositories exist
# - Retrieve modified record ids from source (or all if recent_only: false)
# - Retrieve EAD XML from source for each id
# - Convert EAD XML to json in destination (jsonmodel-from-format)
# - Check records: if destination has record delete it (we cannot overlay)
# - POST json to destination batch import endpoint

# TODO: notifications for failures
$logger = Logger.new($stdout)

ID_GENERATORS = {
  # map each id_X value to an array entry ['id_0', 'id_1', 'id_2', 'id_3']
  'four_part' => lambda { |resource|
    JSON.generate [
      resource.fetch('id_0'),
      resource.fetch('id_1', nil),
      resource.fetch('id_2', nil),
      resource.fetch('id_3', nil)
    ]
  },
  # map each id_X value to a single array entry ['id_0.id_1.id_2.id_3'] (default)
  'smushed' => lambda { |resource|
    JSON.generate([(0..3).map { |i| resource.fetch("id_#{i}", nil) }.compact.join('.')])
  }
}.freeze

def migrator(event:, context:)
  source       = setup_client('source', event)
  destination  = setup_client('destination', event)
  target_uris  = event.fetch('source_target_record_uris', [])
  since        = modified_since(event['recent_only']).to_s
  id_generator = event.fetch('id_generator', 'smushed')

  $logger.info "using source: #{source.config.base_uri}"
  $logger.info "using destination: #{destination.config.base_uri}"
  $logger.info "using modified since: #{since}"
  $logger.info "using id generator: #{id_generator}"

  source.resources(query: { modified_since: since }).each do |resource|
    next unless resource['publish']

    title      = resource['title']
    uri        = resource['uri']
    identifier = ID_GENERATORS.fetch(id_generator).call(resource)
    next if target_uris.any? && !target_uris.include?(resource['uri'])

    $logger.info "[source] using resource #{identifier} (#{title}): #{uri}"
    record = retrieve_resource_description(source, uri_to_id(uri))
    next unless record

    json = convert_record(destination, record, identifier)
    next unless json

    remove_existing_record(destination, identifier)
    import_record(destination, json, identifier)
  end

  true # we're happy =)
end

private

def convert_record(destination, record, identifier)
  base_repo = destination.config.base_repo
  destination.config.base_repo = nil
  $logger.info "[destination] converting resource #{identifier} to importable json"
  response = destination.post('plugins/jsonmodel_from_format/resource/ead', record)
  unless response.result.success?
    if response.parsed['error'] == 'Sinatra::NotFound'
      raise '[destination] jsonmodel plugin is not installed'
    else
      raise "[destination] error converting resource #{identifier} to json: #{response.body}"
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

def import_record(destination, record, identifier)
  $logger.info "[destination] importing resource #{identifier}: #{destination.config.base_uri}"
  destination.post('batch_imports', record)
rescue StandardError => e
  $logger.error e.message
  nil
end

def modified_since(recent_only)
  recent_only ? (DateTime.now - 1.0).to_time.utc.to_i : 0
end

def remove_existing_record(destination, identifier)
  response = destination.get('find_by_id/resources', { query: { 'identifier[]': identifier } })
  response.parsed['resources'].each do |ref|
    $logger.info "[destination] deleting resource #{identifier}: #{ref['ref']}"
    destination.delete File.join('resources', uri_to_id(ref['ref']))
  end
rescue StandardError => e
  $logger.error e.message
  nil
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
