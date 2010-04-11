# TODO
#  switch to xauth
#    ask for u/p once, then save token (https://gist.github.com/304123/17685f51b5ecad341de9b58fb6113b4346a7e39f)


$KCODE = 'u'

%w[rubygems net/http json twitter-text term/ansicolor twitter ].each{|l| require l}

include Term::ANSIColor

class EarlyBird
  
  def initialize(user, pass)
    httpauth = Twitter::HTTPAuth.new(USER, PASS)
    @client = Twitter::Base.new(httpauth)
  end
  
  def highlight(text)
    text.gsub(Twitter::Regex::REGEXEN[:extract_mentions], ' ' + blue('@\2')).
      gsub(Twitter::Regex::REGEXEN[:auto_link_hashtags], ' ' + yellow('#\3'))
  end

  def print_tweet(sn, text)
    print sn(sn) , ': ', highlight(text), "\n"
  end

  def sn(sn)
    red(bold(sn))
  end

  def process(data)
    if data['friends']
      # initial dump of friends
    elsif data['text'] #tweet
      print_tweet(data['user']['screen_name'], data['text'])
    elsif data['event']
      case data['event']
      when 'favorite'
        u = @client.user(data['source']['id'])
        s = @client.status(data['target_object']['id'])
        print sn(u.screen_name), ' favorited: ' + "\n"
        print "\t"
        print_tweet(s.user.screen_name, s.text)
      when 'retweet'
        u = @client.user(data['source']['id'])
        s = @client.status(data['target_object']['id'])
        print sn(u.screen_name), ' rewtweeted: ' + "\n"
        print "\t"
        print_tweet(s.user.screen_name, s.text)
      when 'unfollow', 'follow', 'block'
        s = @client.user(data['source']['id'])
        t = @client.user(data['target']['id'])
        print sn(s['screen_name']), ' ', data['event'], 'ed', ' ', sn(t['screen_name']), "\n"
      else
        puts "unknown event: #{data['event']}"
        puts data
      end
    else
      puts 'unknown message'
      puts data
      puts '===='
    end
  rescue Twitter::RateLimitExceeded
    puts 'event dropped due to twitter rate limit'
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
    lines.map {|line| JSON.parse(line).to_mash rescue nil }.compact
  end

  def run(user, pass, host, path, debug=falses)
    if debug
      $stdin.each_line do |line|
        process(line)
      end
    else
      Net::HTTP.start(host) {|http|
        req = Net::HTTP::Get.new(path)
        req.basic_auth user, pass
        http.request(req) do |response|
          buffer = ''
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
    end
  end
end

print "username: "
user = gets.strip
print "password: "
pass = gets.strip


eb = EarlyBird.new(user, pass)
Hose.new.run(user, pass, 'betastream.twitter.com', '/2b/user.json', ARGV.first == 'debug'){|line| eb.process(line)}