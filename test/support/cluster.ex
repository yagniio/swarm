defmodule Swarm.Cluster do
  def spawn(nodes \\ Application.get_env(:swarm, :nodes, [])) do
    # Turn node into a distributed node with the given long name
    :net_kernel.start([:"primary@127.0.0.1"])

    # Allow spawned nodes to fetch all code from this node
    :erl_boot_server.start([])
    allow_boot(to_charlist("127.0.0.1"))

    case Application.load(:swarm) do
      :ok -> :ok
      {:error, {:already_loaded, :swarm}} -> :ok
    end

    nodes
    |> Enum.map(&Task.async(fn -> spawn_node(&1) end))
    |> Enum.map(&Task.await(&1, 30_000))
  end

  def spawn_node(node_host) do
    {:ok, node} = :slave.start(to_charlist("127.0.0.1"), node_name(node_host), slave_args())
    add_code_paths(node)
    transfer_configuration(node)
    ensure_applications_started(node)
    {:ok, node}
  end

  def stop do
    nodes = Node.list(:connected)

    nodes
    |> Enum.map(&Task.async(fn -> stop_node(&1) end))
    |> Enum.map(&Task.await(&1, 30_000))
  end

  def stop_node(node) do
    :ok = :slave.stop(node)
  end

  defp rpc(node, module, fun, args) do
    :rpc.block_call(node, module, fun, args)
  end

  defp slave_args do
    log_level = "-logger level #{Logger.level()}"
    to_charlist("-loader inet -hosts 127.0.0.1 -setcookie #{:erlang.get_cookie()} " <> log_level)
  end

  defp allow_boot(host) do
    {:ok, ipv4} = :inet.parse_ipv4_address(host)
    :erl_boot_server.add_slave(ipv4)
  end

  defp add_code_paths(node) do
    rpc(node, :code, :add_paths, [:code.get_path()])
  end

  @blacklist [~r/^primary@.*$/, ~r/^remsh.*$/, ~r/^.+_upgrader_.+$/, ~r/^.+_maint_.+$/]

  defp transfer_configuration(node) do
    for {app_name, _, _} <- Application.loaded_applications() do
      for {key, val} <- Application.get_all_env(app_name) do
        rpc(node, Application, :put_env, [app_name, key, val])
      end
    end

    # Our current node might be blacklisted ourself; overwrite config with default
    rpc(node, Application, :put_env, [:swarm, :node_blacklist, @blacklist])
  end

  defp ensure_applications_started(node) do
    rpc(node, Application, :ensure_all_started, [:mix])
    rpc(node, Mix, :env, [Mix.env()])

    for {app_name, _, _} <- Application.loaded_applications() do
      rpc(node, Application, :ensure_all_started, [app_name])
    end

    rpc(node, MyApp.WorkerSup, :start_link, [])
  end

  defp node_name(node_host) do
    node_host
    |> to_string
    |> String.split("@")
    |> Enum.at(0)
    |> String.to_atom()
  end
end
