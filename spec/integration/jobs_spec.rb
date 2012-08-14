require 'spec_helper'
require 'pushy-client'
require 'chef/rest'
require 'timeout'


describe PushyClient::App do

  def echo_yahoo
    'sh ' + File.expand_path('../../support/echo_yahoo_to_tmp_pushytest', __FILE__)
  end

  # Method to start up a new client that will be reaped when
  # the test finishes
  def start_new_clients(*names)
    @clients = {} if !@clients
    names.each do |name|
      raise "Client #{name} already created" if @clients[name]
      @clients[name] = {
        :states => []
      }
    end

    start_clients(*names)
  end

  def start_client(name)
    start_clients(name)
  end

  def start_clients(*names)
    names.each do |name|
      raise "Client #{name} already started" if @clients[name][:client]

      new_client = PushyClient::App.new(
        :service_url_base        => TestConfig.service_url_base,
        :client_private_key_path => TestConfig.client_private_key_path,
        :node_name               => name
      )
      @clients[name][:client] = new_client

      # If we already have a thread, call start here--it will piggyback on the
      # main event loop.
      if @thread
        new_client.start
      else
        @thread = Thread.new do
          new_client.start
          @thread = nil
        end
      end
    end

    # Wait until client is registered with the server
    Timeout::timeout(5) do
      until names.all? { |name| @clients[name][:client].worker }
        sleep 0.02
      end
    end

    names.each do |name|
      client =  @clients[name]

      # Register for state changes
      worker = client[:client].worker
      client[:states] << worker.state
      worker.on_state_change = Proc.new { |state| client[:states] << worker.state }
    end

    Timeout::timeout(5) do
      until names.all? { |name| @clients[name][:client].worker.monitor.online? } &&
        names.all? { |name|
          status = rest.get_rest("pushy/node_states/#{name}")['status']
          status == 'up'
        }
        sleep 0.2
      end
    end
  end

  def stop_client(name)
    client = @clients[name][:client]
    @clients[name][:client] = nil

    raise "Client #{name} already stopped" if !client

    client.stop if client.worker

    # If there are no more clients, kill the EM thread (the first thread
    # that a client has ever run on)
    if !@clients.values.any? { |c| c[:client] }
      EM.run { EM.stop_event_loop }
      if !@thread.join(1)
        puts "Timed out stopping client #{name}.  Killing thread."
        @thread.kill
        @thread = nil
      end
    end
  end

  def kill_client(name)
    client = @clients[name][:client]
    @clients[name][:client] = nil

    raise "Client #{name} already stopped" if !client

    # Do everything client.stop would do, without notifying anyone
    if client.worker
      client.worker.monitor.stop
      client.worker.timer.cancel
      client.worker.command.cancel if client.worker.command
    end

    # If there are no more clients, kill the EM thread (the first thread
    # that a client has ever run on)
    if !@clients.values.any? { |c| c[:client] }
      EM.run { EM.stop_event_loop }
      if !@thread.join(1)
        puts "Timed out stopping client #{name}.  Killing thread."
        @thread.kill
        @thread = nil
      end
    end
  end

  after :each do
    if @clients
      @clients.each do |client_name, client|
        stop_client(client_name)
      end
      @clients = nil
    end
  end

  def wait_for_job_complete(uri)
    job = nil
    begin
      sleep(0.02) if job
      job = get_job(uri)
    end until job['status'] == 'complete'
    job
  end

  def get_job(uri)
    job = rest.get_rest(uri)
    job.delete('id')
    job.delete('created_at')
    job.delete('updated_at')
    job['nodes'].keys.each do |status|
      job['nodes'][status] = job['nodes'][status].sort
    end
    job
  end

  def start_echo_job_on_all_clients
    File.delete('/tmp/pushytest') if File.exist?('/tmp/pushytest')
    start_job_on_all_clients(echo_yahoo)
  end

  def start_job_on_all_clients(command)
    start_job(command, @clients.keys)
  end

  def start_job(command, node_names)
    nodes = node_names.map { |node_name| @clients[node_name] }
    @response = rest.post_rest("pushy/jobs", {
      'command' => command,
      'nodes' => node_names
    })
    # Wait until all have started
    until nodes.all? { |client| client[:states].include?('ready') }
      sleep(0.02)
    end
  end

  def echo_job_should_complete_on_all_clients
    job_should_complete_on_all_clients(echo_yahoo)
    IO.read('/tmp/pushytest').should == "YAHOO\n"*@clients.length
  end

  def job_should_complete_on_all_clients(command)
    job_should_complete(command, @clients.keys)
  end

  def job_should_complete(command, node_names)
    job = wait_for_job_complete(@response['uri'])
    job.should == {
      'command' => command,
      'duration' => 300,
      'nodes' => { 'complete' => node_names.sort },
      'status' => 'complete'
    }
  end

  #
  # Begin tests
  #

  let(:rest) do
    # No auth yet
    Chef::REST.new(TestConfig.service_url_base, false, false)
  end

  context 'with one client' do
    before :each do
      start_new_clients('DONKEY')
    end

    context 'when running a job' do
      before(:each) do
        start_echo_job_on_all_clients
      end

      it 'is marked complete' do
        echo_job_should_complete_on_all_clients
      end
    end
  end

  context 'with a client that is killed and comes back up quickly' do
    before :each do
      start_new_clients('DONKEY')
      kill_client('DONKEY')
      start_client('DONKEY')
    end

    context 'when running a job' do
      before(:each) do
        start_echo_job_on_all_clients
      end

      it 'is marked complete' do
        echo_job_should_complete_on_all_clients
      end
    end
  end

  context 'with a client that is killed and comes back down after a while' do
    before :each do
      start_new_clients('DONKEY')
      kill_client('DONKEY')
      # wait until the server believes the node is down
      Timeout::timeout(5) do
        while true
          status = rest.get_rest('pushy/node_states/DONKEY')['status']
          break if status == 'down'
          sleep 0.2
        end
      end
      # Start that sucker back up
      start_client('DONKEY')
    end

    context 'when running a job' do
      before(:each) do
        start_echo_job_on_all_clients
      end

      it 'is marked complete' do
        echo_job_should_complete_on_all_clients
      end
    end
  end

  context 'with a client that goes down and back up quickly' do
    before :each do
      start_new_clients('DONKEY')
      stop_client('DONKEY')
      start_client('DONKEY')
    end

    context 'when running a job' do
      before(:each) do
        start_echo_job_on_all_clients
      end

      it 'is marked complete' do
        echo_job_should_complete_on_all_clients
      end
    end
  end

  context 'with a client that goes down and back up a while later' do
    before :each do
      start_new_clients('DONKEY')
      stop_client('DONKEY')
      # wait until the server believes the node is down
      Timeout::timeout(5) do
        while true
          status = rest.get_rest('pushy/node_states/DONKEY')['status']
          break if status == 'down'
          sleep 0.2
        end
      end
      # Start that sucker back up
      start_client('DONKEY')
    end

    context 'when running a job' do
      before(:each) do
        start_echo_job_on_all_clients
      end

      it 'is marked complete' do
        echo_job_should_complete_on_all_clients
      end
    end
  end

  context 'with no clients' do
    before(:each) { @clients = {} }

    context 'when running a job' do
      before(:each) do
        start_echo_job_on_all_clients
      end

      it 'the job and node statuses are marked complete' do
        job = wait_for_job_complete(@response['uri'])
        job.should == {
          'command' => echo_yahoo,
          'duration' => 300,
          'nodes' => { },
          'status' => 'complete'
        }
      end
    end
  end

  context 'with three clients' do
    before :each do
      start_new_clients('DONKEY', 'FARQUAD', 'FIONA')
    end

    context 'when running a job' do
      before(:each) do
        start_echo_job_on_all_clients
      end

      it 'the job and node statuses are marked complete' do
        echo_job_should_complete_on_all_clients
      end
    end

    context 'with one tied up in a long-running job' do
      before(:each) do
        start_job('sleep 1', [ 'DONKEY' ])
      end

      context 'and we try to run a new job on all three nodes' do
        before(:each) do
          @nack_job = rest.post_rest("pushy/jobs", {
            'command' => echo_yahoo,
            'nodes' => [ 'DONKEY', 'FARQUAD', 'FIONA' ]
          })
        end

        it 'nacks the one and fails to run, and old job still completes' do
          job_should_complete('sleep 1', [ 'DONKEY' ])

          nack_job = get_job(@nack_job['uri'])
          nack_job.should == {
            'command' => echo_yahoo,
            'duration' => 300,
            'nodes' => {
              'nacked' => [ 'DONKEY' ],
              'aborted_while_ready' => [ 'FARQUAD', 'FIONA' ]
            },
            'status' => 'quorum_failed'
          }
        end
      end
    end
  end

  context 'bad input' do
    it '404s when retrieving a nonexistent job' do
      begin
        rest.get_rest('pushy/jobs/abcdefabcdef807f32d9572f8aafbd03', {
          'command' => echo_yahoo
        })
        throw "GET should not have succeeded"
      rescue
        $!.message.should match(/404/)
      end
    end
  end
end
