defmodule Swarm.TrackerSyncTests do
  use ExUnit.Case, async: false

  import Swarm.Entry
  alias Swarm.IntervalTreeClock, as: Clock
  alias Swarm.Registry, as: Registry

  @moduletag :capture_log

  setup_all do
    Application.put_env(:swarm, :node_whitelist, [~r/primary@/])
    {:ok, _} = Application.ensure_all_started(:swarm)

    on_exit(fn ->
      Application.put_env(:swarm, :node_whitelist, [])
    end)

    :rand.seed(:exs64)

    {:ok, _} = MyApp.WorkerSup.start_link()
    :ok
  end

  setup do
    {:ok, pid} = MyApp.WorkerSup.register()
    meta = %{mfa: {MyApp.WorkerSup, :register, []}}
    name = random_name()

    {lclock, rclock} = Clock.fork(Clock.seed())
    send_sync_request(lclock, [])

    entry(name: _, pid: _, ref: _, meta: _, clock: lclock) = call_track(name, pid, meta)

    # fake handle_replica_event which joins the clocks so that they are in sync
    rclock = Clock.join(rclock, Clock.peek(lclock))

    [name: name, pid: pid, meta: meta, lclock: lclock, rclock: rclock]
  end

  test ":sync should set sync node and preserve node clock", %{rclock: rclock} do
    {_, state_before} = :sys.get_state(Swarm.Tracker)
    GenServer.cast(Swarm.Tracker, {:sync, self(), rclock})
    {_, state_after} = :sys.get_state(Swarm.Tracker)

    assert state_after.sync_node == :"primary@127.0.0.1"
    assert state_after.sync_ref
    assert state_after.clock == state_before.clock
  end

  test ":sync should add missing registration", %{pid: pid, meta: meta, rclock: rclock} do
    name = random_name()

    remote_registry = [
      entry(name: name, pid: pid, ref: nil, meta: meta, clock: Clock.peek(rclock))
    ]

    send_sync_request(rclock, remote_registry)

    assert entry(name: ^name, pid: ^pid, ref: _, meta: ^meta, clock: _) =
             Registry.get_by_name(name)
  end

  test ":sync with same pid and remote clock dominates should update the meta", %{
    name: name,
    pid: pid,
    rclock: rclock
  } do
    rclock = Clock.event(rclock)
    remote_meta = %{new: "meta"}

    remote_registry = [
      entry(name: name, pid: pid, ref: nil, meta: remote_meta, clock: Clock.peek(rclock))
    ]

    send_sync_request(rclock, remote_registry)

    assert entry(name: ^name, pid: ^pid, ref: _, meta: ^remote_meta, clock: _) =
             Registry.get_by_name(name)
  end

  test ":sync with same pid and local clock dominates should ignore entry", %{
    name: name,
    pid: pid,
    rclock: rclock
  } do
    Swarm.Tracker.add_meta(:new_local, "meta_local", pid)

    remote_registry = [
      entry(
        name: name,
        pid: pid,
        ref: nil,
        meta: %{new_remote: "remote_meta"},
        clock: Clock.peek(rclock)
      )
    ]

    send_sync_request(rclock, remote_registry)

    local_meta = %{mfa: {MyApp.WorkerSup, :register, []}, new_local: "meta_local"}

    assert entry(name: ^name, pid: ^pid, ref: _, meta: ^local_meta, clock: _) =
             Registry.get_by_name(name)
  end

  test ":sync with same pid and clock should ignore entry", %{
    name: name,
    pid: pid,
    meta: meta,
    rclock: rclock
  } do
    remote_registry = [
      entry(name: name, pid: pid, ref: nil, meta: %{remote: "meta"}, clock: Clock.peek(rclock))
    ]

    send_sync_request(rclock, remote_registry)

    assert entry(name: ^name, pid: ^pid, ref: _, meta: ^meta, clock: _) =
             Registry.get_by_name(name)
  end

  test ":sync with same pid and concurrent changes should merge data", %{
    name: name,
    pid: pid,
    rclock: rclock
  } do
    Swarm.Tracker.add_meta(:new_local, "meta_local", pid)
    rclock = Clock.event(rclock)

    remote_registry = [
      entry(
        name: name,
        pid: pid,
        ref: nil,
        meta: %{new_remote: "remote_meta"},
        clock: Clock.peek(Clock.event(rclock))
      )
    ]

    send_sync_request(rclock, remote_registry)

    merged_meta = %{
      mfa: {MyApp.WorkerSup, :register, []},
      new_local: "meta_local",
      new_remote: "remote_meta"
    }

    assert entry(name: ^name, pid: ^pid, ref: _, meta: ^merged_meta, clock: _) =
             Registry.get_by_name(name)
  end

  test ":sync with different pid and local clock dominates should kill remote pid", %{
    name: name,
    pid: pid,
    meta: meta,
    rclock: rclock
  } do
    Swarm.Tracker.remove_meta(:mfa, pid)

    {:ok, remote_pid} = MyApp.WorkerSup.register()

    remote_registry = [
      entry(name: name, pid: remote_pid, ref: nil, meta: meta, clock: Clock.peek(rclock))
    ]

    send_sync_request(rclock, remote_registry)

    assert_process_alive?(true, pid)
    assert_process_alive?(false, remote_pid)
  end

  test ":sync with different pid and remote clock dominates should kill local pid", %{
    name: name,
    pid: pid,
    meta: meta,
    rclock: rclock
  } do
    {:ok, remote_pid} = MyApp.WorkerSup.register()
    rclock = Clock.event(rclock)

    remote_registry = [
      entry(name: name, pid: remote_pid, ref: nil, meta: meta, clock: Clock.peek(rclock))
    ]

    send_sync_request(rclock, remote_registry)

    assert_process_alive?(false, pid)
    assert_process_alive?(true, remote_pid)
  end

  test ":sync_recv should discard pending sync request from sync_node", %{
    name: name,
    meta: meta,
    rclock: rclock
  } do
    {:ok, remote_pid} = MyApp.WorkerSup.register()
    rclock = Clock.event(rclock)

    remote_registry = [
      entry(name: name, pid: remote_pid, ref: nil, meta: meta, clock: Clock.peek(rclock))
    ]

    tracker_data = %{
      elem(:sys.get_state(Swarm.Tracker), 1)
      | sync_node: node(self()),
        pending_sync_reqs: [self()]
    }

    :sys.replace_state(Swarm.Tracker, fn _ -> {:syncing, tracker_data} end)

    GenServer.cast(Swarm.Tracker, {:sync_recv, self(), rclock, remote_registry})

    tracker_pid = Process.whereis(Swarm.Tracker)
    assert_receive({:"$gen_cast", {:sync_ack, ^tracker_pid, _, _}})
    refute_receive({:"$gen_cast", {:sync_recv, ^tracker_pid, _, _}})

    assert elem(:sys.get_state(Swarm.Tracker), 0) == :tracking
  end

  defp call_track(name, pid, meta) do
    Swarm.Tracker.track(name, pid)

    Enum.each(meta, fn {k, v} ->
      Swarm.Tracker.add_meta(k, v, pid)
    end)

    Registry.get_by_name(name)
  end

  defp send_sync_request(clock, registry) do
    GenServer.cast(Swarm.Tracker, {:sync, self(), clock})
    GenServer.cast(Swarm.Tracker, {:sync_ack, self(), clock, registry})

    # get_state to wait for the sync to be completed
    :sys.get_state(Swarm.Tracker)

    # flush all messages from the sync process
    receive do
      _ -> :ok
    after
      0 -> :ok
    end
  end

  defp random_name() do
    :rand.uniform()
  end

  defp assert_process_alive?(alive, pid, tries \\ 10)

  defp assert_process_alive?(alive, pid, 0) do
    assert Process.alive?(pid) == alive
  end

  defp assert_process_alive?(alive, pid, tries) do
    if Process.alive?(pid) == alive do
      alive
    else
      # get_state to drain the message queue and retry...
      :sys.get_state(Swarm.Tracker)
      assert_process_alive?(alive, pid, tries - 1)
    end
  end
end
