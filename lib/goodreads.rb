# frozen_string_literal: true

require 'gender_detector'
require 'nokogiri'
require 'oauth'
require 'pry'
require 'typhoeus'
require 'uri'

module Goodreads
  Book = Struct.new :image_url, :isbn, :title, keyword_init: true

  HOST = URI::HTTPS.build host: 'www.goodreads.com'
  API_KEY = ENV.fetch 'GOODREADS_API_KEY'
  SECRET  = ENV.fetch 'GOODREADS_SECRET'
  OAUTH_CONSUMER = OAuth::Consumer.new API_KEY, SECRET, site: HOST.to_s
  GENDER_DETECTOR = GenderDetector.new

  module_function

  def request_token
    OAUTH_CONSUMER.get_request_token
  rescue Net::HTTPBadResponse, Net::OpenTimeout
    # Starting with the simplest fix. If this doesn't work, the next idea
    # is to create a new consumer here and retry.
    tries ||= 0
    tries += 1
    retry if tries < 4
  end

  def fetch_shelves goodreads_user_id
    uri = HOST
    uri.path = '/shelf/list.xml'
    uri.query = URI.encode_www_form user_id: goodreads_user_id, key: API_KEY

    doc = Nokogiri::XML Typhoeus.get(uri).body
    shelf_names = doc.xpath('//shelves//name').children.to_a
    shelf_books = doc.xpath('//shelves//book_count').children.map(&:to_s).map!(&:to_i)

    shelf_names.zip shelf_books
  end

  def get_books shelf_name, goodreads_user_id
    uri = HOST
    uri.path = "/review/list/#{goodreads_user_id}.xml"
    uri.query = URI.encode_www_form shelf: shelf_name, per_page: '200', key: API_KEY

    get_book_details get_requests uri, number_of_pages(uri)
  end

  def number_of_pages uri
    doc = Nokogiri::XML Typhoeus.get(uri).body
    doc.xpath('//books').first&.[]('numpages').to_i
  end

  def get_requests uri, number_of_pages
    hydra = Typhoeus::Hydra.new
    requests = Array.new number_of_pages do |page|
      request = Typhoeus::Request.new "#{uri}&page=#{page}"
      hydra.queue request
      request
    end
    hydra.run

    requests
  end

  def get_book_details requests
    # TODO: make this a hash instead of array
    requests.flat_map do |request|
      doc = Nokogiri::XML request.response.body
      isbns = doc.xpath('//isbn').children.map(&:text)
      image_urls = doc.xpath('//book/image_url').children.map(&:text).grep_v(/\A\n\z/)
      titles = doc.xpath('//title').children.map(&:text)
      authors = doc.xpath('//authors/author/name').children.map(&:text)
      published_years = doc.xpath('//published').children.map(&:text)

      isbns.zip image_urls, titles, authors, published_years
    end
  end

  def fetch_user access_token
    uri = HOST
    uri.path = '/api/auth_user'
    response = access_token.get uri.to_s
    xml = Nokogiri::XML response.body
    user_id = xml.xpath('//user').first.attributes.first[1].value
    first_name = xml.xpath('//user').first.children[1].children.text

    [user_id, first_name]
  end

  def get_gender isbnset
    grouped = isbnset.group_by do |_, _, _, name|
      GENDER_DETECTOR.get_gender name.split.first
    end
    count = grouped.transform_values(&:size)
    mostly_female = count.values_at(:female, :mostly_female).compact.sum
    mostly_male = count.values_at(:male, :mostly_male).compact.sum
    androgynous = count.fetch :andy, 0

    [mostly_female, mostly_male, androgynous]
  end

  def plot_books_over_time isbnset
    isbnset.map { |_, _, _, title, year| [title, Integer(year)] if year }.compact!
  end

  def fetch_book_data isbn
    uri = HOST
    uri.path = "/book/isbn/#{isbn}"
    response = Typhoeus.get uri, params: {key: API_KEY}
    case response.code
    when 200
      doc = Nokogiri::XML(response.body)
      title = doc.xpath('//title').text
      image_url = doc.xpath('//image_url').first.text
      book = Book.new title: title, image_url: image_url, isbn: isbn

      [:ok, book]
    else
      [:error, response.code]
    end
  end
end
