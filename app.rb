# frozen_string_literal: true

system 'roda-parse_routes', '-f', 'routes.json', __FILE__

require 'area'
require 'roda'
require 'rollbar/middleware/rack'
require 'securerandom'
require 'tilt'
require 'zbar'
require_relative 'lib/bookmooch'
require_relative 'lib/db'
require_relative 'lib/goodreads'
require_relative 'lib/models'
require_relative 'lib/overdrive'
require_relative 'lib/tuple_space'

class App < Roda
  use Rollbar::Middleware::Rack

  plugin :assets, css: 'styles.css'
  plugin :public, root: 'assets'
  plugin :flash
  plugin :sessions, secret: ENV.fetch('SESSION_SECRET')
  plugin :slash_path_empty
  plugin :render
  compile_assets

  CACHE = TupleSpace.new

  def cache_set **pairs
    pairs.each do |key, value|
      CACHE["#{session['session_id']}/#{key}"] = value
    end
  end

  def cache_get key
    CACHE["#{session['session_id']}/#{key}"]
  end

  def request_token
    cached_token = cache_get :request_token
    return cached_token if cached_token

    token = Goodreads.request_token
    cache_set request_token: token
    token
  end

  # TODO: extract to goodreads lib
  def goodreads_user_id
    return session['goodreads_user_id'] if session['goodreads_user_id']

    access_token = begin
                     request_token.get_access_token
                   rescue OAuth::Unauthorized
                     return
                   end

    goodreads_user_id, first_name = Goodreads.fetch_user access_token

    @users.insert(first_name: first_name, goodreads_user_id: goodreads_user_id) unless @users.first(goodreads_user_id: goodreads_user_id)
    @user = @users.first(goodreads_user_id: goodreads_user_id)

    env['rollbar.person_data'] = {id: @user[:id], username: @user[:first_name]}
    session['goodreads_user_id'] = goodreads_user_id
  end

  route do |r|
    r.public
    r.assets

    @books = DB[:books]
    @users = DB[:users]

    session['session_id'] ||= SecureRandom.uuid

    r.root do
      @auth_url = request_token.authorize_url
      # route: GET /
      r.get true do
        view 'welcome'
      end
    end

    r.on 'login' do
      # route: GET /login
      r.get do
        r.redirect '/shelves'
      end
    end

    # TODO: change this so I'm not passing stuff back and forth from cache unnecessarily
    r.on 'shelves' do
      # route: GET /shelves
      r.get true do
        if goodreads_user_id
          @shelves = Goodreads.fetch_shelves goodreads_user_id
          view 'shelves/index'
        else
          r.redirect '/'
        end
      end

      r.on String do |shelf_name|
        r.redirect '/' unless goodreads_user_id

        @shelf_name = shelf_name
        cache_set shelf_name: @shelf_name

        @book_info = cache_get @shelf_name.to_sym
        unless @book_info
          @book_info = Goodreads.get_books @shelf_name, goodreads_user_id
          cache_set(@shelf_name.to_sym => @book_info)
        end

        # route: GET /shelves/:id
        r.get true do
          @women, @men, @andy = Goodreads.get_gender @book_info
          @histogram_dataset = Goodreads.plot_books_over_time @book_info

          view 'shelves/show'
        end

        r.on 'bookmooch' do
          # route: GET /shelves/:id/bookmooch
          r.get true do
            view 'shelves/bookmooch'
          end

          # route: POST /shelves/:id/bookmooch?username=foo&password=baz
          r.post do
            r.halt(403) if r['username'] == 'susanb'
            @books_added, @books_failed = Bookmooch.books_added_and_failed @book_info, r['username'], r['password']
            cache_set books_added: @books_added, books_failed: @books_failed

            r.redirect 'bookmooch/results'
          end

          # route: GET /shelves/:id/bookmooch/results
          r.get 'results' do
            @books_added = cache_get :books_added
            @books_failed = cache_get :books_failed
            view 'bookmooch'
          end
        end

        r.on 'overdrive' do
          # TODO: have browser get their location
          # route: GET /shelves/:id/overdrive
          r.get true do
            view 'shelves/overdrive'
          end

          # route: POST /shelves/:id/overdrive?consortium=1047
          r.post do
            titles = Overdrive.new(@book_info, r['consortium']).fetch_titles_availability
            cache_set titles: titles
            r.redirect '/availability'
          end
        end
      end
    end

    r.on 'availability' do
      # route: GET /availability
      r.get do
        @titles = cache_get :titles
        unless @titles
          flash[:error] = 'Please choose a shelf first'
          r.redirect 'shelves'
        end
        view 'availability'
      end
    end

    # TODO: add library logos to the cards in the views
    r.on 'library' do
      # route: POST /library?zipcode=90029
      r.post do
        @shelf_name = cache_get :shelf_name
        zip = r['zipcode']

        if zip.empty?
          flash[:error] = 'You need to enter a zip code'
          r.redirect "shelves/#{@shelf_name}/overdrive"
        end

        unless zip.to_latlon
          flash[:error] = 'please try a different zip code'
          r.redirect "shelves/#{@shelf_name}/overdrive"
        end

        @local_libraries = Overdrive.local_libraries zip.to_latlon.delete ' '

        cache_set libraries: @local_libraries
        r.redirect '/library'
      end

      # route: GET /library
      r.get do
        @shelf_name = cache_get :shelf_name
        @local_libraries = cache_get :libraries
        # TODO: see if we can bring the person back to the choose a library stage rather than all the way back to choose a shelf
        unless @local_libraries
          flash[:error] = 'Please choose a shelf first'
          r.redirect 'shelves'
        end
        view 'library'
      end
    end

    r.on 'inventory' do
      # route: GET /inventory/new
      r.get 'new' do
        view 'inventory/new'
      end

      # route: GET /inventory/:id
      r.get Integer do |book_id|
        @book = @books.first(id: book_id)
        @user = @users.first(id: @book[:user_id])
        view 'inventory/show'
      end

      # route: POST /inventory/create?barcode_image="isbn.jpg"
      r.post 'create' do
        image = r[:barcode_image][:tempfile]
        barcodes = ZBar::Image.from_jpeg(image).process

        if barcodes.any?
          r.redirect '/' unless goodreads_user_id
          user = @users.first goodreads_user_id: goodreads_user_id

          barcodes.each do |barcode|
            isbn = barcode.data
            status, book = Goodreads.fetch_book_data isbn

            raise "#{status}: #{book}" unless status == :ok

            @books.insert isbn: isbn, user_id: user[:id], cover_image_url: book.image_url, title: book.title
          end
          r.redirect '/inventory/index'
        else
          flash[:error] = 'no barcode detected, please try again'
          r.redirect '/inventory/new'
        end
      end

      # route: GET /inventory
      r.get do
        view 'inventory/index'
      end
    end

    r.on 'about' do
      # route: GET /about
      r.get do
        view 'about'
      end
    end

    r.on 'users' do
      r.redirect '/' unless @user

      # TODO: write authorization for these routes properly
      # route: GET /users
      r.get true do
        if @user&.dig(:id) == 1
          view 'users/index'
        else
          view 'welcome'
        end
      end

      r.on String do |id|
        # route: GET /users/:id
        r.get true do
          @id = id
          if @user == @users.first(id: @id)
            view 'users/show'
          else
            view 'welcome'
          end
        end

        # route: GET /users/:id/edit
        r.get 'edit' do
          view 'users/edit'
        end

        # route: POST /users/:id
        r.post true do
          @user.update!(email: r.params['email'], first_name: r.params['first_name'], last_name: r.params['last_name'])
          view 'users/show'
        end
      end
    end
  end
end
