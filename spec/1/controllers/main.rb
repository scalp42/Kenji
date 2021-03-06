
class MainController < Kenji::Controller

  get '/hello' do
    {status: 200, hello: :world}
  end

  get '/crasher' do
    raise
  end

  post '/' do
    {status:1337}
  end

  put '/' do
    {status:1337}
  end

  delete '/' do
    {status:1337}
  end

  get '/respond' do
    kenji.respond(123, 'hello')
    raise # never called
  end
end
