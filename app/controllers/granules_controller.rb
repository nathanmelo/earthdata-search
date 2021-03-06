class GranulesController < ApplicationController
  include GranuleUtils

  respond_to :json

  def create
    granule_params = granule_params_for_request(request)
    catalog_response = echo_client.get_granules(granule_params, token)
    metrics_event('filter', granule_params)

    if catalog_response.success?
      catalog_response.headers.each do |key, value|
        response.headers[key] = value if key.start_with?('cmr-')
      end

      render json: catalog_response.body, status: catalog_response.status
    else
      render json: catalog_response.body, status: catalog_response.status
    end
  end

  def show
    response = echo_client.get_granule(params[:id], {}, token)

    if response.success?
      respond_with(GranuleDetailsPresenter.new(response.body.first, params[:id], token, cmr_env), status: response.status)
    else
      respond_with(response.body, status: response.status)
    end
  end

  def timeline
    catalog_response = echo_client.post_timeline(granule_params_for_request(request), token)
    render json: catalog_response.body, status: catalog_response.status
  end

  class GranuleUrlStreamer
    def initialize(params, token, url_mapper, echo_client, url_type=:download)
      params.reject!{|p| ['datasource', 'short_name'].include? p}
      @params = params
      @token = token
      @url_mapper = url_mapper
      @echo_client = echo_client
      @url_type = url_type
    end

    def first
      catalog_response = @echo_client.get_granules(@params.merge(page_num: 1), @token)
      if catalog_response.success?
        granules = catalog_response.body['feed']['entry']

        granule = granules.first
        first_info = @url_mapper.info_urls_for(granule).first
        return first_info if first_info

        @url_mapper.send("#{@url_type}_urls_for", granule).first
      else
        @errors = catalog_response.body
        nil
      end
    end

    def each
      yielded_info = false
      at_end = false
      page = 1
      page_size = @params["page_size"]
      until at_end
        catalog_response = @echo_client.get_granules(@params.merge(page_num: page), @token)
        hits = catalog_response.headers['CMR-Hits'].to_i

        if catalog_response.success?
          granules = catalog_response.body['feed']['entry']
          at_end = page_size * page >= hits

          granules.each do |granule|
            unless yielded_info
              @url_mapper.info_urls_for(granule).each do |url|
                yield url
                yielded_info = true
              end
            end

            @url_mapper.send("#{@url_type}_urls_for", granule).each do |url|
              yield url
            end
          end

          page += 1
        else
          @errors = catalog_response.body
          return
        end
      end
    end
  end

  def fetch_links
    retrieval = Retrieval.find(request[:project])
    collection_id = params[:collection]
    user = current_user
    unless user == retrieval.user
      render file: "#{Rails.root}/public/403.html", status: :forbidden
      return
    end

    page_num = params.delete('page_num') || 1
    browse_only = params.delete('browse')
    url_type = 'download'
    url_type = 'browse' if browse_only == true || browse_only == 'true'

    project = retrieval.project
    collection = Array.wrap(project['collections']).find {|ds| ds['id'] == collection_id}

    query = Rack::Utils.parse_nested_query(collection['params'])
    catalog_response = echo_client.get_granules(query.merge({page_num: page_num, page_size: 2000, format: :json}), token)

    if catalog_response.success?
      hits = catalog_response.headers['CMR-Hits'].to_i
      granules = catalog_response.body['feed']['entry']
      url_mapper = OpendapConfiguration.find(collection_id, echo_client, token)
      if url_type == 'download'
        method = collection['serviceOptions']['accessMethod'].find { |m| m['type'] == 'download' }
        url_mapper.apply_subsetting(method['subset'])
      end

      fetched_links = []
      fetched_info = false

      granules.each do |granule|
        unless fetched_info
          url_mapper.info_urls_for(granule).each do |url|
            fetched_links << url
          end
          fetched_info = true
        end

        url_mapper.send("#{url_type}_urls_for", granule).each do |url|
          fetched_links << url
        end
      end
      # Set custom header causes local rails server to throw 'socket hang up' error.
      # response.headers['CMR-Hits'] = hits
      response_body = {}
      response_body['CMR-Hits'] = hits
      response_body['links'] = fetched_links
      render json: response_body, status: catalog_response.status
    else
      render json: catalog_response.body, status: catalog_response.status
    end

  end

  # def download_script
  def download
    retrieval = Retrieval.find(request[:project])
    collection_id = request[:collection]
    user = current_user
    unless user == retrieval.user
      render file: "#{Rails.root}/public/403.html", status: :forbidden
      return
    end

    project = retrieval.project
    collection = Array.wrap(project['collections']).find {|ds| ds['id'] == collection_id}

    query = Rack::Utils.parse_nested_query(collection['params'])

    url_type = :download
    url_type = :browse if request[:browse] == true || request[:browse] == 'true'

    if request.format == 'html'
      page_num = params.delete('page_num') || 1
      @query = query.merge({'project' => request[:project], 'page_num' => page_num, 'page_size' => 2000, 'browse' => (url_type.to_s == 'browse'), 'collection' => collection_id})
      render stream: true, layout: false
      return
    end

    url_mapper = OpendapConfiguration.find(collection_id, echo_client, token)

    if url_type == :download
      method = collection['serviceOptions']['accessMethod'].find { |m| m['type'] == 'download' }
      url_mapper.apply_subsetting(method['subset'])
    end

    @urls = GranuleUrlStreamer.new(query.merge('page_size' => 2000), token, url_mapper, echo_client, url_type)

    @user = earthdata_username
    render stream: true, layout: false
  end
end
