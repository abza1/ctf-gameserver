#!/usr/bin/env python3

import base64
import errno
import json
import logging
import os
import pickle
import socket
import ssl
import sys
import threading
from typing import Any, Type

import ctf_gameserver.lib.flag
from ctf_gameserver.lib.checkresult import CheckResult


_TIMEOUT_SECONDS = 10.0    # Default timeout for socket operations
_LOCAL_STATE_PATH = '_state.json'

_ctrl_in = None    # pylint: disable=invalid-name
_ctrl_out = None    # pylint: disable=invalid-name
_ctrl_out_lock = None    # pylint: disable=invalid-name


def _setup():

    global _ctrl_in, _ctrl_out, _ctrl_out_lock    # pylint: disable=invalid-name
    if 'CTF_CHECKERSCRIPT' in os.environ:
        # Launched by Checker Runner, we cannot just try to open the descriptors (and fallback if they don't
        # exist) because execution environments like pytest might use them as well
        _ctrl_in = os.fdopen(3, 'r')
        _ctrl_out = os.fdopen(4, 'w')
    else:
        # Local execution without a Checker Runner
        logging.basicConfig()
        logging.getLogger().setLevel(logging.INFO)
        return

    _ctrl_out_lock = threading.RLock()

    class JsonHandler(logging.StreamHandler):
        def __init__(self):
            super().__init__(_ctrl_out)

        def emit(self, record):
            _ctrl_out_lock.acquire()
            super().emit(record)
            _ctrl_out_lock.release()

        def format(self, record):
            param = {
                'message': super().format(record),
                'levelno': record.levelno,
                'pathname': record.pathname,
                'lineno': record.lineno,
                'funcName': record.funcName
            }
            json_message = {'action': 'LOG', 'param': param}
            # Make sure that our JSON consists of just a single line
            return json.dumps(json_message).replace('\n', '')

    json_handler = JsonHandler()
    logging.getLogger().addHandler(json_handler)
    logging.getLogger().setLevel(logging.INFO)

    socket.setdefaulttimeout(_TIMEOUT_SECONDS)
    try:
        import requests    # pylint: disable=import-outside-toplevel

        # Ugly monkey patch to set defaults for the timeouts in requests, because requests (resp. urllib3)
        # always overwrites the default socket timeout
        class TimeoutSoup(requests.adapters.TimeoutSauce):
            def __init__(self, total=None, connect=None, read=None):
                if total is None:
                    total = _TIMEOUT_SECONDS
                if connect is None:
                    connect = _TIMEOUT_SECONDS
                if read is None:
                    read = _TIMEOUT_SECONDS
                super().__init__(total, connect, read)
        requests.adapters.TimeoutSauce = TimeoutSoup
    except ImportError:
        pass


_setup()


class BaseChecker:
    """
    Base class for individual Checker implementations. Checker Scripts must implement all methods.

    Attributes:
        ip: Vulnbox IP address of the team to be checked
        team: ID of the team to be checked
    """

    def __init__(self, ip: str, team: int) -> None:
        self.ip = ip
        self.team = team

    def place_flag(self, tick: int) -> CheckResult:
        raise NotImplementedError('place_flag() must be implemented by the subclass')

    def check_service(self) -> CheckResult:
        raise NotImplementedError('check_service() must be implemented by the subclass')

    def check_flag(self, tick: int) -> CheckResult:
        raise NotImplementedError('check_flag() must be implemented by the subclass')


def get_flag(tick: int, payload: bytes = b'') -> str:
    """
    May be called by Checker Scripts to get the flag for a given tick, for the team and service of the
    current run. The returned flag can be used for both placement and checks.
    """

    if _launched_without_runner():
        try:
            team = get_flag._team    # pylint: disable=protected-access
        except AttributeError:
            raise Exception('get_flag() must be called through run_check()')
        # Return dummy flag when launched locally
        if payload == b'':
            payload = None
        return ctf_gameserver.lib.flag.generate(team, 42, b'TOPSECRET', payload, tick)

    payload_b64 = base64.b64encode(payload).decode('ascii')
    _send_ctrl_message({'action': 'FLAG', 'param': {'tick': tick, 'payload': payload_b64}})
    result = _recv_ctrl_message()
    return result['response']


def store_state(key: str, data: Any) -> None:
    """
    Allows a Checker Script to store arbitrary Python data persistently across runs. Data is stored per
    service and team with the given key as an additional identifier.
    """

    serialized_data = base64.b64encode(pickle.dumps(data)).decode('ascii')

    if not _launched_without_runner():
        message = {'key': key, 'data': serialized_data}
        _send_ctrl_message({'action': 'STORE', 'param': message})
        # Wait for acknowledgement
        _recv_ctrl_message()
    else:
        try:
            with open(_LOCAL_STATE_PATH, 'r') as f:
                state = json.load(f)
        except FileNotFoundError:
            state = {}
        state[key] = serialized_data
        with open(_LOCAL_STATE_PATH, 'w') as f:
            json.dump(state, f, indent=4)


def load_state(key: str) -> Any:
    """
    Allows to retrieve data stored through store_state(). If no data exists for the given key (and the
    current service and team), None is returned.
    """

    if not _launched_without_runner():
        _send_ctrl_message({'action': 'LOAD', 'param': key})
        result = _recv_ctrl_message()
        data = result['response']
        if data is None:
            return None
    else:
        try:
            with open(_LOCAL_STATE_PATH, 'r') as f:
                state = json.load(f)
        except FileNotFoundError:
            return None
        try:
            data = state[key]
        except KeyError:
            return None

    return pickle.loads(base64.b64decode(data))


def run_check(checker_cls: Type[BaseChecker]) -> None:
    """
    Launch execution of the specified Checker implementation. Must be called by all Checker Scripts.
    """

    if len(sys.argv) != 4:
        raise Exception('Invalid arguments, usage: {} <ip> <team> <tick>'.format(sys.argv[0]))

    ip = sys.argv[1]
    team = int(sys.argv[2])
    tick = int(sys.argv[3])

    if _launched_without_runner():
        # Hack because get_flag() only needs to know the team when launched locally
        get_flag._team = team    # pylint: disable=protected-access

    checker = checker_cls(ip, team)
    result = _run_check_steps(checker, tick)

    if not _launched_without_runner():
        _send_ctrl_message({'action': 'RESULT', 'param': result.value})
        # Wait for acknowledgement
        _recv_ctrl_message()
    else:
        print('Check result: {}'.format(result))


def _run_check_steps(checker, tick):

    tick_lookback = 5

    try:
        logging.info('Placing flag')
        result = checker.place_flag(tick)
        logging.info('Flag placement result: %s', result)
        if result != CheckResult.OK:
            return result

        logging.info('Checking service')
        result = checker.check_service()
        logging.info('Service check result: %s', result)
        if result != CheckResult.OK:
            return result

        current_tick = tick
        oldest_tick = max(tick-tick_lookback, 0)
        recovering = False
        while current_tick >= oldest_tick:
            logging.info('Checking flag of tick %d', current_tick)
            result = checker.check_flag(current_tick)
            logging.info('Flag check result of tick %d: %s', current_tick, result)
            if result != CheckResult.OK:
                if current_tick != tick and result == CheckResult.FLAG_NOT_FOUND:
                    recovering = True
                else:
                    return result
            current_tick -= 1

        if recovering:
            return CheckResult.RECOVERING
        else:
            return CheckResult.OK
    except Exception as e:    # pylint: disable=broad-except
        if _is_timeout(e):
            logging.warning('Timeout during check', exc_info=e)
            return CheckResult.TIMEOUT
        elif isinstance(e, ssl.SSLError):
            logging.warning('SSL error during check', exc_info=e)
            return CheckResult.FAULTY
        else:
            # Just let the Checker Script die, logging will be handled by the Runner
            raise e


def _launched_without_runner():
    """
    Returns True if the Checker Script has been launched locally (during development) and False if it has
    been launched by the Checker Script Runner (during an actual competition).
    """
    return _ctrl_in is None


def _recv_ctrl_message():

    message_json = _ctrl_in.readline()
    return json.loads(message_json)


def _send_ctrl_message(message):

    # Make sure that our JSON consists of just a single line
    message_json = json.dumps(message).replace('\n', '') + '\n'

    _ctrl_out_lock.acquire()
    _ctrl_out.write(message_json)
    _ctrl_out.flush()
    _ctrl_out_lock.release()


def _is_timeout(exception):
    """
    Checks if the given exception resembles a timeout/connection error.
    """

    timeout_exceptions = (
        EOFError,    # Raised by telnetlib on timeout
        socket.timeout,
        ssl.SSLEOFError,
        ssl.SSLZeroReturnError,
        ssl.SSLWantReadError,
        ssl.SSLWantWriteError
    )
    try:
        import urllib3    # pylint: disable=import-outside-toplevel
        have_urllib3 = True
        timeout_exceptions += (
            urllib3.exceptions.ConnectionError,
            urllib3.exceptions.NewConnectionError,
            urllib3.exceptions.ReadTimeoutError
        )
    except ImportError:
        have_urllib3 = False
    try:
        import requests    # pylint: disable=import-outside-toplevel
        have_requests = True
        timeout_exceptions += (
            requests.exceptions.ConnectTimeout,
            requests.exceptions.Timeout,
            requests.packages.urllib3.exceptions.ConnectionError,
            requests.packages.urllib3.exceptions.NewConnectionError
        )
    except ImportError:
        have_requests = False
    try:
        import nclib    # pylint: disable=import-outside-toplevel
        timeout_exceptions += (nclib.NetcatError,)
    except ImportError:
        pass

    if isinstance(exception, timeout_exceptions):
        return True

    if isinstance(exception, OSError):
        return exception.errno in (
            errno.ECONNABORTED,
            errno.ECONNREFUSED,
            errno.ECONNRESET,
            errno.EHOSTDOWN,
            errno.EHOSTUNREACH,
            errno.ENETDOWN,
            errno.ENETRESET,
            errno.ENETUNREACH,
            errno.EPIPE,
            errno.ETIMEDOUT
        )

    if have_urllib3:
        if isinstance(exception, urllib3.exceptions.MaxRetryError):
            return _is_timeout(exception.reason)
        if isinstance(exception, urllib3.exceptions.ProtocolError):
            return len(exception.args) == 2 and _is_timeout(exception.args[1])
    if have_requests:
        if isinstance(exception, requests.exceptions.ConnectionError):
            return len(exception.args) == 1 and _is_timeout(exception.args[0])
        if isinstance(exception, requests.packages.urllib3.exceptions.MaxRetryError):
            return _is_timeout(exception.reason)
        if isinstance(exception, requests.packages.urllib3.exceptions.ProtocolError):
            return len(exception.args) == 2 and _is_timeout(exception.args[1])

    return False