from docker.bintray.io/jfrog/xray-installer:2.9.0
COPY ./wrapper.sh /opt/jfrog/xray/xray-installer/
RUN chmod +x /opt/jfrog/xray/xray-installer/wrapper.sh
CMD ["./wrapper.sh"]
