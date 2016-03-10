defmodule Mix.Tasks.Compile.WpaSupplicant do
  use Mix.Task

  @shortdoc "Compiles the wpa_ex port binary"
  def run(_) do
    {exec, args} = case :os.type do
      {:win32, _} ->
        {"nmake", ["/F", "Makefile.win", "priv\\wpa_ex"]}
      {:unix, :freebsd} ->
        {"gmake", ["priv/wpa_ex"]}
      {:unix, :openbsd} ->
        {"gmake", ["priv/wpa_ex"]}
      _ ->
        {"make", ["priv/wpa_ex"]}
    end

     if System.find_executable(exec) do
       build(exec, args)
       Mix.Project.build_structure
       :ok
     else
       nocompiler_error(exec)
     end
  end

  def build(exec, args) do
    {result, error_code} = System.cmd(exec, args, stderr_to_stdout: true)
    IO.binwrite result
    if error_code != 0, do: build_error(exec)
  end

  defp nocompiler_error("nmake") do
    raise Mix.Error, message: nocompiler_message("nmake") <> windows_message
  end
  defp nocompiler_error(exec) do
    raise Mix.Error, message: nocompiler_message(exec) <> nix_message
  end

  defp build_error("nmake") do
    raise Mix.Error, message: build_message <> windows_message
  end
  defp build_error(_) do
    raise Mix.Error, message: build_message <> nix_message
  end

  defp nocompiler_message(exec) do
    """
    Could not find the program `#{exec}`.
    You will need to install the C compiler `#{exec}` to be able to build
    NervesWifi.
    """
  end

  defp build_message do
    """
    Could not compile NervesWifi.
    Please make sure that you are using Erlang / OTP version 17.0 or later
    and that you have a C compiler installed.
    """
  end

  defp windows_message do
    """
    One option is to install a recent version of Visual Studio (the
    free Community edition will be enough for this task) and then, in
    Visual Studio:
    Go to File > New > Project
    Choose C++, it will prompt to install the module.
    Close and restart Visual Studio.
    Go to search > "Developer Command Prompt for VS2015"
    cd to the VC directory, run `vcvarsall.bat amd64` -- this must be run every time you try to compile nerves_wifi
    cd over to your project and run `mix deps.get`, and then `mix deps.compile`.
    """
  end

  defp nix_message do
    """
    Please follow the directions below for the operating system you are
    using:
    Mac OS X: You need to have gcc and make installed. Try running the
    commands `gcc --version` and / or `make --version`. If these programs
    are not installed, you will be prompted to install them.
    Linux: You need to have gcc and make installed. If you are using
    Ubuntu or any other Debian-based system, install the packages
    `build-essential`. Also install `erlang-dev` package if not
    included in your Erlang/OTP version.
    """
  end

end
