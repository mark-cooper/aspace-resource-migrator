# frozen_string_literal: true

load 'vendor/bundle/bundler/setup.rb'
require 'archivesspace/client'
require 'logger'

# - Setup connections (source and dest)
# - Verify source and destination repositories exist
# - Retrieve modified record ids from source (or all if recent_only: false)
# - Skip processing if destination has record and cfg does not allow updates
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

# TODO: re-org this (need to handle enum misses in general)
TRANSFORMERS = {
  ead: [
    ->(record) { record.gsub(/level="other level"/, 'level="otherlevel"') }
  ],
  json: [
    ->(record) { record.gsub(/"publish":false/, '"publish":true') }
  ]
}

def migrator(event:, context:)
  source        = setup_client('source', event)
  destination   = setup_client('destination', event)
  target_uris   = event.fetch('source_target_record_uris', [])
  since         = modified_since(event['recent_only']).to_s
  id_generator  = event.fetch('id_generator', 'smushed')
  skip_existing = event.fetch('destination_skip_existing', false)
  log_setup(source, destination, target_uris, since, id_generator, skip_existing)

  source.resources(query: { modified_since: since }).each do |resource|
    next unless resource['publish']

    title      = resource['title']
    uri        = resource['uri']
    identifier = ID_GENERATORS.fetch(id_generator).call(resource)
    destination_uri = find_uri(destination, identifier)
    next if target_uris.any? && !target_uris.include?(resource['uri'])
    next if destination_uri && skip_existing

    $logger.info "[source] using resource #{identifier} (#{title}): #{uri}"
    record = retrieve_resource_description(source, uri_to_id(uri))
    next unless record

    TRANSFORMERS[:ead].each { |t| record = t.call(record) }
    json = convert_record(destination, record, identifier)
    next unless json

    TRANSFORMERS[:json].each { |t| json = t.call(json) }
    remove_existing_record(destination, destination_uri) if destination_uri
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

def find_repository(client, repository)
  client.repositories.find { |r| r['repo_code'] == repository }
end

def find_uri(client, identifier)
  response = client.get('find_by_id/resources', { query: { 'identifier[]': identifier } })
  response.parsed.fetch('resources').map { |r| r['ref'] }.first
rescue StandardError => e
  $logger.error e.message
  nil
end

def import_record(destination, record, identifier)
  $logger.info "[destination] importing resource #{identifier}: #{destination.config.base_uri}"
  destination.post('batch_imports', record)
rescue StandardError => e
  $logger.error e.message
  nil
end

def log_setup(source, destination, target_uris, since, id_generator, skip_existing)
  $logger.info "using source: #{source.config.base_uri} [#{source.config.base_repo}]"
  $logger.info "using destination: #{destination.config.base_uri} [#{destination.config.base_repo}]"
  $logger.info "using targets: #{target_uris}" if target_uris.any?
  $logger.info "using modified since: #{since}"
  $logger.info "using id generator: #{id_generator}"
  $logger.info "using skip existing: #{skip_existing}"
end

def modified_since(recent_only)
  recent_only ? (DateTime.now - 1.0).to_time.utc.to_i : 0
end

def remove_existing_record(destination, uri)
  $logger.info "[destination] deleting resource #{identifier}: #{uri}"
  destination.delete File.join('resources', uri_to_id(uri))
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
  repo_code = event["#{role}_repo_code"].strip
  client = ArchivesSpace::Client.new(setup(role, event)).login
  repository = find_repository(client, repo_code)
  fatal_error "[#{role}] invalid repository: #{repo_code}" unless repository

  client.config.base_repo = repository['uri']
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
