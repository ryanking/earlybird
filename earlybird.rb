# TODO
#  switch to xauth
#    ask for u/p once, then save token (https://gist.github.com/304123/17685f51b5ecad341de9b58fb6113b4346a7e39f)

$KCODE = 'u'

%w[rubygems pp net/http json twitter-text term/ansicolor twitter highline/import getoptlong tempfile open-uri].each{|l| require l}

include Term::ANSIColor

class EarlyBird

  def initialize(user, pass, filter, track)
    httpauth = Twitter::HTTPAuth.new(user, pass)
    @client = Twitter::Base.new(httpauth)
    @friends = []
    @filter = filter
    @screen_name = user
    @track = Array(track) + Array(user)
    @icons = {}
  end

  def highlight(text)
    text.gsub(Twitter::Regex::REGEXEN[:extract_mentions], ' ' + cyan('@\2')).
      gsub(Twitter::Regex::REGEXEN[:auto_link_hashtags], ' ' + yellow('#\3'))
  end

  def search_highlight(text)
    highlight(text)
    @track.inject(text) do |newtext, term|
      newtext.gsub /#{term}/i do |match|
        green(match)
      end
    end
  end

  def fetch_icon_for_user(user)
    user_id = user['id'].to_i
    unless @icons.has_key?(user_id)
      Tempfile.open(user['screen_name']) do |file|
        file.print open(user['profile_image_url']).read
        @icons[user_id] = file.path
      end
    end
    @icons[user_id]
  end

  def growl_tweet(data)
    return unless $growl

    icon_path = fetch_icon_for_user(data['user'])
    Growl.notify(data['text'], :title => data['user']['screen_name'], :icon => icon_path)
  end

  def print_tweet(sn, text)
    print sn(sn) , ': ', highlight(text), "\n"
  end

  def print_search(sn, text)
    print sn(sn) , ': ', search_highlight(text), "\n"
  end

  def sn(sn)
    red(bold(sn))
  end

  def user_and_status(user_id, status_id)
    u = @client.user(user_id)
    s = @client.status(status_id)
    [u, s]
  rescue Twitter::General => e
    raise e unless e.message =~ /403/
  end

  # If it's an @reply but not to somebody you follow (or to you), then we drop it
  def passes_filter(data)
    # If it's sent by you, then it passes
    if data['user']['screen_name'] == @screen_name
      return true
    end

    in_reply_to = data['user']['in_reply_to_user_id']

    if in_reply_to
      # If it's sent to a friend of yours or to you then it passes
      @friends.include?(in_reply_to) or (data['user']['in_reply_to_screen_name'] == @screen_name)
    else
      # If it's not an @reply then it passes.
      true
    end
  end

  def print_tweet_from_data(data)
    if $filter
      if passes_filter(data)
        print_tweet(data['user']['screen_name'], data['text'])
        growl_tweet(data)
      end
    else
      print_tweet(data['user']['screen_name'], data['text'])
      growl_tweet(data)
    end
  end

  def print_retweet_from_data(data)
    print sn(data['user']['screen_name']), " retweeted: " + "\n\t"
    print_tweet(data['retweeted_status']['user']['screen_name'], data['retweeted_status']['text'])
    growl_tweet(data)
  end

  def process(data)
    if data['friends']
      # initial dump of friends
      @friends = data['friends']
    elsif data['sender'] #dm
      print "direct message: \n\t"
      print_tweet(data['sender_screen_name'], data['text'])
    elsif data['text'] #tweet
      # If it's from a friend or from yourself, treat as a tweet.
      if @friends.include?(data['user']['id']) or (data['user']['screen_name'] == @screen_name)
        if data['retweeted_status']
          print_retweet_from_data(data)
        else
          print_tweet_from_data(data)
        end
      else
        print "search result: \n\t"
        print_search(data['user']['screen_name'], data['text'])
      end
    elsif data['event']
      case data['event']
      when 'favorite', 'unfavorite'
        u, s = user_and_status(data['source']['id'], data['target_object']['id'])
        print sn(u.screen_name), ' ', data['event'], 'd', "\n"
        print "\t"
        print_tweet(s.user.screen_name, s.text)
      when 'unfollow', 'follow', 'block'
        s = @client.user(data['source']['id'])
        t = @client.user(data['target']['id'])
        print sn(s['screen_name']), ' ', data['event'], 'ed', ' ', sn(t['screen_name']), "\n"
      when 'retweet'
        #ignore
      else
        puts "unknown event: #{data['event']}"
        puts data
      end
    elsif data['limit'] && data['limit']['track']
      puts bold("rate limited on track...")
    elsif data['delete']
      # ignore deletes
    else
      puts 'unknown message'
      p data
      puts '===='
    end
  rescue Twitter::RateLimitExceeded
    puts "event dropped due to twitter rate limit (reset in #{@client.rate_limit_status['reset_time_in_seconds'] - Time.now} seconds)"
    p @client.rate_limit_status
  end
end

class Hose
  KEEP_ALIVE  = /\A3[\r][\n][\n][\r][\n]/
  DECHUNKER   = /\A[0-F]+[\r][\n]/
  NEWLINE     = /[\n]/
  CRLF        = /[\r][\n]/
  EOF         = /[\r][\n]\Z/

  def unchunk(data)
    data.gsub(/\A[0-F]+[\r][\n]/, '')
  end

  def keep_alive?(data)
    data =~ KEEP_ALIVE
  end

  def extract_json(lines)
    # lines.map {|line| Yajl::Stream.parse(StringIO.new(line)).to_mash rescue nil }.compact
    lines.map {|line| JSON.parse(line).to_hash rescue nil }.compact
  end

  # filter determines whether you remove @replies from users you don't follow
  def run(user, pass, host, path, debug=false, filter=false)
    if debug
      $stdin.each_line do |line|
        process(line)
      end
    else
      begin
        Net::HTTP.start(host) {|http|
          req = Net::HTTP::Get.new(path)
          req.basic_auth user, pass
          http.request(req) do |response|
            buffer = ''
            raise response.inspect unless response.code == '200'
            response.read_body do |data|
              unless keep_alive?(data)
                buffer << unchunk(data)

                if buffer =~ EOF
                  lines = buffer.split(CRLF)
                  buffer = ''
                else
                  lines = buffer.split(CRLF)
                  buffer = lines.pop
                end

                extract_json(lines).each {|line| yield(line)}
              end
            end
          end
        }
      rescue Errno::ECONNRESET, EOFError
        puts "disconnected from streaming api, reconnecting..."
        sleep 5
        retry
      end
    end
  end
end

user = ask("Enter your username:  ")
pass = ask("Enter your password:  ") { |q| q.echo = '*' }

def usage
  puts "usage: earlybird.rb [-d] [-f] [-t key,words] [-u url] [-h host]"
  puts "options: "
  puts "  -d debug mode, read json from stdin"
  puts "  -f filter out @replies from users you don't follow"
  puts "  -g growl notifications for new tweets"
  puts "  -t track keywords separated by commas."
  puts "  -u userstream path. Default: /2b/user.json"
  puts "  -h userstream hostname: Default: chirpstream.twitter.com"
end

opts = GetoptLong.new(
      [ '--help', GetoptLong::NO_ARGUMENT ],
      [ '-d', GetoptLong::OPTIONAL_ARGUMENT ],
      [ '-f', GetoptLong::OPTIONAL_ARGUMENT ],
      [ '-g', GetoptLong::OPTIONAL_ARGUMENT ],
      [ '-t', GetoptLong::OPTIONAL_ARGUMENT],
      [ '-h', GetoptLong::OPTIONAL_ARGUMENT]
    )

$debug = false
$filter = false
$growl = false
$track = []
$url = '/2b/user.json'
$host = 'chirpstream.twitter.com'

opts.each do |opt, arg|
  case opt
  when '--help'
    usage
    exit 0
  when '-f'
    $filter = true
  when '-g'
    require 'growl'
    $growl = true
  when '-d'
    $debug = true
  when '-t'
    $track = arg.split(",")
  when '-u'
    $url = arg
  when '-h'
    $host = arg
  end
end

unless $track.empty?
  puts "tracking term #{$track}"
  $url << "?track=" + CGI::escape($track.join(","))
end

puts "connecting to http://#{$host}#{$url}"

eb = EarlyBird.new(user, pass, $filter, $track)
Hose.new.run(user, pass, $host, $url, $debug){|line| eb.process(line)}
