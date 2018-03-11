# frozen_string_literal: true

require 'area'
require 'base64'
require 'http'
require 'nokogiri'
require 'oauth'
require 'oauth2'
require 'pry'
require 'roda'
require 'rollbar/middleware/rack'
require 'tilt'
require 'uri'
require 'zbar'
require_relative 'db'
require_relative 'models'
require_relative 'tuple_space'


class App < Roda
  use Rollbar::Middleware::Rack
  plugin :assets, css: 'styles.css'
  plugin :public, root: 'assets'
  plugin :render
  compile_assets

  CACHE = ::TupleSpace.new

  APP_URI               = 'http://localhost:9292'
  BOOKMOOCH_URI         = 'http://api.bookmooch.com'
  GOODREADS_URI         = 'https://www.goodreads.com'
  OVERDRIVE_KEY         = ENV['OVERDRIVE_KEY']
  OVERDRIVE_LIBRARY_URI = 'https://api.overdrive.com/v1/libraries/'
  OVERDRIVE_MAPBOX_URI  = 'https://www.overdrive.com/mapbox/find-libraries-by-location'
  OVERDRIVE_SECRET      = ENV['OVERDRIVE_SECRET']

  use Rack::Session::Cookie, secret: ENV['GOODREADS_SECRET'], api_key: ENV['GOODREADS_API_KEY']

  route do |r|
    r.public
    r.assets

    session[:secret] = ENV['GOODREADS_SECRET']
    session[:api_key] = ENV['GOODREADS_API_KEY']
    users = DB[:users]

    r.root do

      consumer = OAuth::Consumer.new session[:api_key], session[:secret], site: GOODREADS_URI
      request_token = consumer.get_request_token oauth_callback: "#{APP_URI}/import"

      session[:request_token] = request_token
      @auth_url = request_token.authorize_url

      # GET /
      r.get do
        view 'welcome' # renders views/foo.erb inside views/layout.erb
      end
    end

    r.on 'shelves' do
      # GET /import
      r.get do
        if session[:goodreads_user_id]
          users.insert_conflict.insert(goodreads_user_id: session[:goodreads_user_id])
        else
          access_token = session[:request_token].get_access_token
          response = access_token.get "#{GOODREADS_URI}/api/auth_user"
          xml = Nokogiri::XML response.body
          user_id = xml.xpath('//user').first.attributes.first[1].value
          first_name = xml.xpath('//user').first.children[1].children.text

          users.insert_conflict.insert(first_name: first_name, goodreads_user_id: user_id)

          session[:goodreads_user_id] = user_id
        end

        params = URI.encode_www_form(user_id: session[:goodreads_user_id],
                                     key: session[:api_key])

        path = "/shelf/list.xml?#{params}}"

        HTTP.persistent GOODREADS_URI do |http|
          doc = Nokogiri::XML http.get(path).body

          puts 'Getting shelves...'

          @shelf_names = doc.xpath('//shelves//name').children.to_a
          @shelf_books = doc.xpath('//shelves//book_count').children.to_a
        end

        @shelves = @shelf_names.zip(@shelf_books)
        view 'shelves'
      end

      error do |e|
      end

    end

    r.on 'request_books' do
      # POST /request_books
      r.post do

        session[:shelf_name] = r['shelf_name'].gsub('\"', '')

        r.redirect '/request_books'
      end

      # GET /books
      r.get do
        params = URI.encode_www_form(shelf: session[:shelf_name],
                                     per_page: '20',
                                     key: session[:api_key])
        path = "/review/list/#{session[:goodreads_user_id]}.xml?#{params}}"

        HTTP.persistent GOODREADS_URI do |http|
          doc = Nokogiri::XML http.get(path).body

          puts 'Counting pages...'
          @number_of_pages = doc.xpath('//books').first['numpages'].to_i
          puts "Found #{@number_of_pages} pages..."

          @isbnset = 1.upto(@number_of_pages).flat_map do |page|
            "Fetching page #{page}..."
            doc = Nokogiri::XML http.get("#{path}&page=#{page}").body
            isbns = doc.xpath('//isbn').children.map &:text
            image_urls = doc.xpath('//book/image_url').children.map(&:text).grep_v /\A\n\z/
            titles = doc.xpath('//title').children.map &:text
            isbns.zip(image_urls, titles)
          end
        end

        CACHE["#{session[:session_id]}/isbns_and_image_urls"] = @isbnset
        @invalidzip = r.params['invalidzip']

        view 'request_books'
      end
    end

    r.on 'bookmooch' do
      # POST /bookmooch?username=foo&password=baz
      r.post do
        isbns_and_image_urls = CACHE["#{session[:session_id]}/isbns_and_image_urls"]
        unless r['username'] == 'susanb'
          auth = {user: r['username'], pass: r['password']}
        end
        @books_added = []
        @books_failed = []

        HTTP.basic_auth(auth).persistent(BOOKMOOCH_URI) do |http|
          if isbns_and_image_urls
            isbns_and_image_urls.each do |isbn, image_url, title|
              params = {asins: isbn, target: 'wishlist', action: 'add'}
              puts "Params: #{URI.encode_www_form params}"
              puts 'Adding to wishlist with bookmooch api...'
              response = http.get '/api/userbook', params: params

              if response.body.to_s.strip == isbn
                @books_added << [title, image_url]
              else
                @books_failed << [title, image_url]
              end
            end
          else
            r.redirect '/books'
          end
        end

        CACHE["#{session[:session_id]}/books_added"] = @books_added
        CACHE["#{session[:session_id]}/books_failed"] = @books_failed
        r.redirect '/bookmooch'
      end

      # GET /bookmooch
      r.get do
        @books_added = CACHE["#{session[:session_id]}/books_added"]
        @books_failed = CACHE["#{session[:session_id]}/books_failed"]
        view 'bookmooch'
      end
    end

    r.on 'library' do
      # POST /library?zipcode=90029
      r.post do
        @local_libraries = []
        CACHE["#{session[:session_id]}/libraries"] = @local_libraries
        zip = r['zipcode']

        if zip.to_latlon
          latlon = r['zipcode'].to_latlon.delete ' '
        else
          r.redirect "books?invalidzip=#{zip}"
        end

        response = HTTP.get(OVERDRIVE_MAPBOX_URI, :params => {:latLng => latlon, :radius => 50})
        libraries = JSON.parse response.body

        libraries.first(10).each do |l|
          consortium_id = l["consortiumId"]
          consortium_name = l["consortiumName"]
          @local_libraries << [consortium_id, consortium_name]
        end

        CACHE["#{session[:session_id]}/libraries"] = @local_libraries
        r.redirect '/library'
      end

      # GET /library
      r.get do
        @local_libraries = CACHE["#{session[:session_id]}/libraries"]
        view 'library'
      end
    end

    r.on 'availability' do
      # POST /availability?consortium=1047
      r.post do

        # Pulling book info from the cache
        @isbnset = CACHE["#{session[:session_id]}/isbns_and_image_urls"]
        @titles = @isbnset.map {|book| URI.encode(book[2])}

        # Getting auth token from overdrive
        client = OAuth2::Client.new(OVERDRIVE_KEY, OVERDRIVE_SECRET, :token_url => '/token', :site =>'https://oauth.overdrive.com')
        token_request = client.client_credentials.get_token
        token = token_request.token

        # Four digit library id from user submitted form
        consortium_id = r['consortium'].gsub('\"', '') # 1047

        # Getting the library-specific endpoint
        library_uri = OVERDRIVE_LIBRARY_URI + "#{consortium_id}"
        response = HTTP.auth("Bearer #{token}").get(library_uri)
        res = JSON.parse(response.body)
        collectionToken = res["collectionToken"] # "v1L1BDAAAAA2R"

        # The URL that I need to provide to the user to actually click on and
        # visit so that they can check out the book is in this format:
        # https://lapl.overdrive.com/media/c8a88fb7-c369-454c-b113-9703b1816d57
        # where the id is at the end of the url
        # the only thing i need to figure out is the subdomain at the beginning, AKA 'lapl'
        # because the book id stays the same

        # Making the API call to Library Availability endpoint
        availability_uri = "https://api.overdrive.com/v1/collections/#{collectionToken}/products?q=#{@titles.first}"
        response = HTTP.auth("Bearer #{token}").get(availability_uri)
        res = JSON.parse(response.body)
        p res
        book_availibility_url = res["products"].first["links"].assoc("availability").last["href"]
        p book_availibility_url

        # Checking if the book is available
        response = HTTP.auth("Bearer #{token}").get(book_availibility_url)
        res = JSON.parse(response.body)
        copiesOwned = res["copiesOwned"]
        copiesAvailable = res["copiesAvailable"]

        r.redirect '/availability'
      end

      # GET /availability
      r.get do
        view 'availability'
      end
    end

    r.on 'about' do
      # GET /about
      r.get do
        view 'about'
      end
    end

    r.on 'inventory' do
      r.on 'new' do
        # GET /inventory/new
        r.get do
          # isbn = ZBar::Image.from_jpeg(File.binread('isbn.jpg')).process.first.data
          view 'inventory/new'
        end
      end

      # GET /inventory
      r.get do
        view 'inventory'
      end
    end

  end
end
